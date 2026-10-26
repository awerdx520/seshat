# 架构设计

## 概述

个人笔记同步系统是单用户、云 VPS 自托管的个人知识中枢，三端协作 + LLM 增值：

- 桌面端 Emacs（org-mode）负责笔记编辑，文件同步复用 org-mode 设施
- Android 端负责电子书阅读/批注（epub/pdf，mobi 转 epub）与 org GTD 查看
- 服务端统一汇总文件、附件与三端阅读状态，提供 WebDAV、REST、git 版本化、静态加密、全文索引与 LLM 能力

## 核心决策（P0，用户确认）

1. 加密语义：静态加密（SQLCipher + 磁盘 LUKS，服务端可读明文做索引）
2. 技术栈：服务端 Go、Android Kotlin 原生、桌面端 elisp
3. 部署：云 VPS
4. WebDAV：双重定位（内部同步通道 + 对外标准出口）
5. 访问控制：单用户（Bearer 令牌 + WebDAV Basic Auth 同令牌）
6. 冲突处理：服务端 git 版本化 + ETag 乐观锁 + 自有客户端三方合并（ADR-001）
7. 对外 WebDAV：可读写 + 范围受限（笔记目录 + 文件类型白名单）+ 每次写自动 commit
8. LLM 后端：混合（云端 API + 本地处理节点），本地节点为纯推理节点、结果明文回传，无 E2EE（ADR-002）

## 模块划分（服务端）

| 模块 | 职责 |
|---|---|
| `cmd/server` | 入口：装配配置、日志、存储、git 版本库、索引、认证与路由（装配失败即退出） |
| `internal/config` | 配置加载（config.yaml + 环境变量覆盖），含 `webdav.roots` 归一化与校验 |
| `internal/auth` | 单用户认证（主令牌 + 可选节点令牌） |
| `internal/storage` | SQLite(SQLCipher) + 文件系统 + git 版本库；M7 新增身份三表（见下） |
| `internal/logging` | 结构化日志与稳定错误码（`logging.Code`） |
| `internal/webdav` | WebDAV 服务：内部 `/dav/` 与对外 `/public/` 双出口，写后 commit + FTS 索引 + **registry 钩子** |
| `internal/api` | REST API：状态、资源登记、路径解析、根映射、文件读写、变更流、引用、维护重扫等端点类别（M7 新增后七类） |
| `internal/index` | 全文索引 FTS5（仅覆盖笔记根） |
| `internal/llm` | LLM 接入层（云端 + 本地处理节点） |
| `internal/registry` | **M7 新增**：文件身份与增量同步地基——uid 生成/校验、事件应用（`resources` + `changes` 同事务）、引用解析（`refs`）、文件系统 → 登记表的 bootstrap / rescan |

**`internal/storage` 的三张新表**（v6 单条迁移建档；v7 只重建状态表，不动这三张）：

| 表 | 键 | 职责 |
|---|---|---|
| `resources` | `uid` 主键 + `UNIQUE(root, path)` | 服务端权威文件身份登记：uid 跨改名稳定，`path` 是可变属性，删除写墓碑（`deleted_at`）不物理删行 |
| `changes` | `seq INTEGER PRIMARY KEY AUTOINCREMENT` | 全局单调变更日志（`create`/`update`/`rename`/`delete`），客户端游标的唯一基准，无 TTL |
| `refs` | `(source_uid, source_location, target_uid, target_location)` | 引用图：`seshat:` 链接解析结果的落地，支持「我引用了谁 / 谁引用了我」双向查询 |

`internal/webdav` 的 **registry 钩子**（`registryAfterWrite`）包在 commit 钩子外层、FTS 索引钩子内层，仅 2xx 写响应生效：把「文件已落盘」的事实登记为身份与事件，与 REST 写路径共用同一个 `registry.Apply`，因此两个出口写入同一文件得到同一个 uid。

`internal/api` 的新端点类别（细节见 [`docs/api.md`](api.md)）：资源登记（`/api/resources`、`/api/resources/{uid}`）、路径解析（`/api/resolve`）、根映射（`/api/roots`）、文件读写（`/api/files/{path...}`、`/api/resources/{uid}/move`）、变更流（`/api/changes`）、引用（`/api/refs`）与维护（`/api/resources/rescan`）。

## 身份与增量同步（M7）

M7 把「按路径 / 内容哈希识别文件」换成「服务端权威 **uid** 识别文件」，把「客户端全量遍历比对」换成「**全局游标**拉增量」。本节只列要点，完整契约见 [`docs/sync-protocol.md`](sync-protocol.md)，设计依据见 [ADR-003](adr/0003-uid-identity-model.md)（uid 身份模型）与 [ADR-004](adr/0004-incremental-change-log.md)（变更日志与游标）。

1. **uid 是身份，路径是属性**：uid 由服务端生成（16 字节随机 → 26 位 Crockford Base32），改名/移动只改 `resources.path`；删除写墓碑（`deleted_at`）不物理删行，同一路径重建时复用原 uid。
2. **三张表承载三件事**：`resources`（身份登记）、`changes`（变更日志）、`refs`（引用图）；状态表 `reading_progress`/`annotations` 在 v7 起直接以 uid 为键。
3. **单一全局游标**：`changes.seq` 跨全部根共用一个单调递增序列，客户端只持久化一个整数 `cursor`；`changed_at` 不是游标。
4. **多根**：首根 `mirror`（笔记根，WebDAV 全量镜像 + FTS + git，可写），其余 `ondemand`（书库根，只经 REST 按需读，写请求 → `403 root_read_only`）。
5. **写路径顺序固定**：落盘 → commit → registry → refs。登记是**派生状态**且失败只记日志（不改变已发出的响应），缺口由 `POST /api/resources/rescan` 兜底修复。
6. **状态 API 只接受 uid**：形态非法 → `400 invalid_uid`；形态合法但未登记/已墓碑 → `404 unknown_uid`（破坏性变更，见 `docs/api.md` §14）。

服务端内部写入顺序（WebDAV 与 REST 共用）：

| # | 步骤 | 实现位置 |
|---|---|---|
| 1 | 落盘 + commit（同一持锁临界区） | `gitver.WriteAndCommit` / `RenameAndCommit` / `RemoveAndCommit` |
| 2 | 登记身份与变更事件（单事务 upsert `resources` + append `changes`） | `registry.Apply` |
| 3 | `.org` 写成功后**整份替换**该源的引用 | `registry.RefreshRefs` / `ClearRefs` |

其它既有的同步通道不变：文件（org / 附件 / 电子书）走 WebDAV 或 REST 文件端点、ETag 乐观锁；状态（阅读进度 / 批注）走 REST、后写覆盖 + 时间戳冲突检测；附件（二进制）按内容寻址存储（SHA256）且「附件清单」纳入 git。

### 客户端侧批注同步约定（离线优先）

Emacs 阅读器（`seshat-reader`）的批注同步在客户端侧叠加一层**离线队列**，用于吸收服务端不可用时的创建/删除操作。约定如下：

- **离线入队**：create/delete 在服务端不可用时写入本地队列（`seshat-reader-annotation-queue-file`，原子写），不报错；列表离线时仍渲染本地项并标 `[待同步]`。
- **create 幂等去重**：同步前先拉取该文档现有批注，比对 `(location, text)`；若已存在完全相同的批注即视为已同步、**不重复 POST**。
- **delete 视为成功**：删除返回的 **404 视为成功**（幂等删除——服务端已无此批注即达成目标）；其它非 2xx 或异常才停止本轮。
- **失败即停**：任一条同步失败即停止本轮，该条及其后续项保留在队列中待下次同步（不丢弃、不报错）。
- **服务端零改动**：队列与同步均为**客户端侧**行为，不改变服务端 REST 契约（端点行为与 `location`/`text` 语义不变；文档键 M7 起为 uid，队列条目相应携带 `:uid`，缺 `:uid` 的旧条目跳过并提示）。

## Emacs 客户端同步分层（M8-A）

M8 把 Emacs 端同步器从 WebDAV 传输迁到 REST，分三层落地，本节点只记录地基（计划 A）已完成的部分：

| 层 | 文件 | 职责 |
|---|---|---|
| 传输层 | `emacs/seshat-transport.el` | 统一 HTTP 契约 `(:status :headers :body)`；**永不抛错**（失败只回报 `:status nil` + `:error`）；后端可换：`rest`（`url.el` + Bearer，默认）与 `webdav`（`curl` + Basic，灰度期保留） |
| API 层 | `emacs/seshat-rest.el` | 服务端端点封装（roots / resources / changes / files / move / versions）与统一状态码解释；`seshat-rest--request` 保留为**薄包装**（旧 `(status . body)` 契约 + 抛错语义不变，保护既有 4 处调用方） |
| 状态层 | `emacs/seshat-state.el` | 单一 `.eld` 原子写：全局 `cursor`、per-uid `base-blob`（取代旧的单文件 head）、`uid ↔ (root . path)` 双索引、`dirty` 集合、墓碑 |

**分层约束**：传输层抛错责任在 API 层，不得上提；二进制下载必须传 `:binary t`（否则 `url.el` 后端会按 UTF-8 解码破坏字节）。**接入进度**：M8-B 已接入增量循环、条件写、move 检测与冲突合并（见下一节）；计划 C（M8-C）已补上书架 / 按需取书与 `seshat:` uid 形态的 follow（见「书架与按需取书（M8-C）」节）。

## Emacs 增量同步引擎（M8-B）

M8-B 把同步从「全量遍历 + 路径身份 + WebDAV 弱乐观锁」切到「增量游标 + uid 身份 + REST 条件写」。执行顺序固定：

```
seshat-sync-now
  ├─ seshat-sync-pull          首同步：预建索引 → changes 追平取游标
  │                            增量：从状态库游标继续
  ├─ seshat-sync-detect-renames 本地 size/mtime 快照比对 → mark-dirty；rename 配对 → POST move
  ├─ seshat-sync-push          遍历 dirty → If-Match / If-None-Match 条件写 → 412 走三方合并
  └─ seshat-sync-status        逐 uid 拉阅读进度（失败不阻塞前三步）
```

**三条不变量**：

1. **游标最后写**：每批「apply → 批量块退出重建索引 → 推进游标 → 落盘」，中断后从落盘游标重放是幂等的；
2. **首同步职责分离**：`changes?since=0` 是权威全集，`/api/resources` 分页只是尽力而为的预建（同秒超一页会丢记录，由 changes 补齐）；
3. **零交互**：push 的 412 分支与 rename 检测都可能由定时器触发，任何分支都不得询问用户或用 smerge 进入文件；冲突标记写回本地后提示用户手动处理。

**根映射**：`seshat-sync-roots`（`(TAG DIR MODE)`）是唯一配置入口，`seshat-sync--ensure-roots` 在首次 pull 时把它写入状态库（`MODE` 为 nil 时向 `GET /api/roots` 取权威值）；改配置后需 `M-x seshat-sync-reset-roots`。

## 书架与按需取书（M8-C）

M8-C 在 M8-A/M8-B 之上新增**一层**：`emacs/seshat-library.el`（项目层，与 `seshat-sync.el` / `seshat-state.el` 同级，**不属于** vendored 的 `seshat-reader` 包）。它补的是同步引擎留下的两个缺口——`ondemand` 根「只登记不下载」与「本地副本无刷新入口」。

| 层 | 文件 | 职责 |
|---|---|---|
| 数据层 | `emacs/seshat-library.el`（`seshat-library--roots` / `--remote-entries` / `--local-state` / `seshat-library-fetch`） | 读远端 `ondemand` 根清单（`:since-mtime` 翻页）、判本地三态、按需取书（六步事务，见 [`docs/sync-protocol.md`](sync-protocol.md)「Emacs 客户端按需取书实现要点（M8-C）」） |
| UI 层 | 同一文件的 `seshat-library-mode`（`tabulated-list-mode` 派生）+ `seshat-library` / `-open-at-point` / `-refresh-at-point` / `-delete-local-at-point` | 书架 buffer `*Seshat Library*`：四列（书名 / 根 / 大小 / 状态）、`RET` / `u` / `d` / `g` / `q` 五键 |

**依赖方向（单向，无环）**：

| 依赖 | 内容 |
|---|---|
| `seshat-library` → `seshat-rest` / `seshat-state` / `seshat-sync` | 项目层依赖基础设施层与引擎层（路径校验、游标推进、位置登记） |
| `seshat-library` → `seshat-reading` → `seshat-reader/**` | 书架 `RET` 经 `seshat-reading-open` 打开文档（单向：library → reading → reader） |
| `seshat-reader/**` 不得依赖 `seshat-library` | **禁止反向 require**：reader 是 vendored 包，需取书的两处一律软依赖（`fboundp` 探测 + `declare-function`） |

- `seshat-library` 复用 `seshat-sync` 的**路径安全校验**（`seshat-sync--local-path`）、**游标推进**（`seshat-sync--next-since-mtime`）与**位置登记**（`seshat-sync--event-set-location`），不另写一份——另写必然与引擎漂移。
- `emacs/seshat-reader/**` **不得 require** `seshat-library`：reader 是 vendored 包，反向依赖会让它在没有项目层时无法加载。需要取书的两处一律**软依赖**：`fboundp` 探测 + `declare-function`（`seshat-reader-reference--fetch-library` 调 `seshat-library-fetch`；`:follow` 的 uid 分支由它托管）。缺函数时 `user-error` 说明缺什么，**不自行 require**（否则成环）。
- `seshat-reading-open` 也是软依赖：`seshat-library` 用 `(require 'seshat-reading nil t)` 探测，缺失时书架 `RET` 退化为 `find-file`——可选依赖缺失不该让「打开一本书」失败。

**三条不变量**：

1. **`d`（删本地副本）零网络**：只用 buffer-local 缓存的清单重算状态列（`seshat-library--redisplay`），不走 `tabulated-list-revert`（那条路挂着「重拉远端清单」）。远端文件一律保留。
2. **所有落盘路径都过 `seshat-sync--local-path`**：服务端下发的相对路径不可信（拒绝 `..`、绝对路径、盘符、`~`、符号链接逃逸），取书与删本地副本共用这一处校验，不自行拼路径字符串。
3. **`ondemand` 根绝不写远端**：`seshat-library` 只发 `GET`；服务端对书库根的写入本就 `403 root_read_only`，客户端不制造撞墙的机会。

**为什么书架读的是状态库而不是配置变量**：`seshat-library--roots` 从 `seshat-state-roots`（状态库里的根映射）筛 `MODE` 为 `ondemand` 的根——与同步引擎同源，避免「书架认一套根、同步认另一套」。代价是**首次使用前必须先跑过一次同步**（`M-x seshat-sync-now` 把 `seshat-sync-roots` 写入状态库），改配置后需 `M-x seshat-sync-reset-roots`。

## `seshat:` 引用协议（M11.4）

笔记与阅读器之间的双向引用通道，格式为 **`seshat:<target>[#<location>]`**，`<target>` 有两种形态（见下「双形态」）：

| 场景 | 链接 |
|---|---|
| 整本书 | `seshat:ebook:d2l-zh-pytorch.pdf` |
| 某页 | `seshat:ebook:d2l-zh-pytorch.pdf#page:112` |
| 某区域（批注级） | `seshat:ebook:d2l-zh-pytorch.pdf#page:112;rect:50.00,100.00,545.00,140.00` |
| 不在任何书库根下的文档 | `seshat:local:/abs/path.pdf#page:3` |

**解析规则**：

- 剥掉 `seshat:` 前缀后，按**最后一个** `#` 分割为 doc-id 与 location（doc-id 自身含 `:`，如 `ebook:` 标签与 `local:` 绝对路径，故不能按 `:` 或首个 `#` 切分）；
- **不做任何百分号转义**：不使用 `url-hexify-string`（它会把 `:`、`/` 一并转义，破坏 doc-id 可读性并切断与批注文档键（M7 起为 uid，展示与链接仍用 doc-id 文本）的复用），也不自造 `%23` 链路（org 自身会对 `%` 二次转义，双重转义无法自洽）；
- 因此 **doc-id 不得包含 `#` 与 `%`**：构造链接时检测到这两个字符即 `user-error` 并提示重命名文件；非法链接解析返回 nil。

**与批注 `location` 的同构关系**：批注的 `location` 是**页锚 + 可选几何尾段**——形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（页锚 `page:<n>` 1-based、唯一导航真值；`rect:` 段是可选几何、页面坐标、只供渲染），链接片段**直接复用同一字符串**（引用锚复用，不新增解析器）。批注侧唯一的构造点是 `seshat-reader-annotation--anchor`（2026-10-25 由 `--location` 改名，语义收窄为「页锚 + 可选几何尾段」；守 `location` 长度上限的 defconst `seshat-reader-annotation--location-max-length` 保留原名，它守的是 API 字段）。批注列表的行携带该字符串（文本属性），故「批注 → 引用」取值不触网；`page:` 段直接传给 `seshat-reader-goto-page`，`rect:` 段在 M11 只做数据保留，自 M12 起在 Emacs 客户端渲染为页面半透明高亮，`ink:` 段自 2026-10-25 起同样渲染为页面手写笔迹（见「Emacs 阅读器：展示层与渲染层（M12）」节与「搜索与 ink 渲染流程」节）。

**双形态（M7 起）**：`<target>` 可以是 **uid**（服务端权威身份，如 `seshat:01J8ZK4Q7M2X9VYB3TR6NDW5PC#page:3`）或 **doc-id 文本**（`tag:path` 或纯 path，人可读、可手写）。服务端解析优先级为 **uid → `tag:path` → 纯 path（默认根）**（`registry.Resolve`）：uid 形态跨改名稳定，doc-id 形态在改名后失效，需重新构造。含 `#`/`%` 的非法 target 仍按上述规则拒绝。

**客户端新增的 `uid:` 前缀（M8-C）**：Emacs 端产出的 uid 形态写作 `seshat:uid:<uid>[#<location>]`——多一个 `uid:` 前缀，既让「根 tag 恰好叫 `uid`」的 doc-id 不被误判（判别靠 `uid:` 之后是否匹配 26 位 Crockford Base32），也让链接形态在文本上一眼可辨。**服务端 `registry.Resolve` 已识别两种 uid 形态**（M8-C T8）：裸 uid（`IsUID`）与客户端产出的显式前缀 `uid:<uid>`（`uid:` 之后须为合法 26 位 Crockford Base32）；`uid:` 之后不合法时**回落** `tag:path`，因此根 tag 名为 `uid` 的配置仍可用。因此 `registry.RefreshRefs` 对两种 uid 形态都能建立引用边，`GET /api/refs` 与客户端产出的链接形态一致。

**refs 表由写路径维护**：`.org` 写入成功后，服务端解析全文 `seshat:` 链接并用 `registry.RefreshRefs` **整份替换**该源的全部引用（先删后插、单事务）；文件被删除或从 `.org` 改成其它扩展名时清空（`ClearRefs`）。目标解析不到只跳过该条（链接可以指向尚未同步的文档），故 `refs` 是**尽力而为**的派生数据，解析失败不阻塞写响应。查询走 `GET /api/refs?uid=&direction=in|out`。

**Emacs 侧的双值分工**：`seshat-reader-annotation--uid`（路径 → `GET /api/resolve` → uid，`file-truename` 内存缓存）只用于状态 API；`seshat-reader-annotation--doc-id`（文件 → `tag:path`）曾只用于显示与链接文本。二者分别落在列表 buffer 的 `seshat-reader-annotation-list-uid` 与 `seshat-reader-annotation-list-document-id`。**M8-C 起链接身份也走 uid**：`seshat-reader-reference.el` 不再是「零改动」的旁观者，新增单一身份入口 `seshat-reader-reference--identity`（按 `seshat-reader-annotation-roots` 得 `(tag . 相对路径)` → 零网络 `seshat-state-uid-for-path` 查 uid），产出链接与链接描述时优先 uid 形态、查不到回落 doc-id 形态（见「书架与按需取书（M8-C）」节与 [`docs/emacs-reader.md`](emacs-reader.md) §8）。

## 阅读器面板分层（M11.7–M11.10）

面板分为「承载层 / 批注渲染层（ETAF，可选）/ 兜底渲染」三层，另有一条独立的**译文/解释 Markdown 文本 buffer 路径**（不经 ETAF）。

**承载层 `seshat-reader-sidebar`（零依赖）**：

- **弹出位置（M11 语义，M12 已扩展）**：`seshat-reader-sidebar-position` 取 `below-selected`（当前窗口下方分割，形如 `*Help*`）或 `at-bottom`（frame 底部整宽）；M12 新增 `left` / `right` 两个 side window 取值并把默认改为 `right`，批注与译文改为 per-kind 独立窗口并存，详见下节「Emacs 阅读器：展示层与渲染层（M12）」。M11 语义下同一时刻只有一个面板窗口，批注与译文**后显示者接管**。
- **必须经 `display-buffer`**：首次显示、gt 的 `:window-config`、popper 重开三条路径都走 `display-buffer`，以保证**幂等**（同 buffer 同 kind 重复显示只复用窗口、不重建）；面板参数由 `seshat-reader-sidebar--display-params` **单一来源**生成。
- **`display-buffer-overriding-action`**：显示时用它包住 action list，使本包布局优先于 popper 在 `display-buffer-alist` 表头插入的规则；popper 重开（裸 `display-buffer`）时改由 `seshat-reader-sidebar-display-buffer` 分流回本包逻辑，故两条路径布局一致。
- **per-kind 尺寸记忆**：`seshat-reader-sidebar--state` 为内存 alist（零依赖）；切换内容前先捕获当前窗口尺寸（比例）存给其 kind，再用目标 kind 记住的尺寸新建窗口；M12 起记忆项带**方向标签**（宽度语义 / 高度语义），方位在宽/高之间切换时不复用旧值。仅会话内有效，不持久化。
- **禁用 `window-toggle-side-windows`**：它是 frame 级全量开关（会连带删除/恢复 eca-chat、which-key 的侧窗），toggle 只对本包面板窗口做 `delete-window`。

**渲染层 `seshat-reader-etaf`（可选，依赖 `etaf-ui`；只负责批注卡片）**：

- 职责（M11.10 起）：**仅渲染批注卡片列表**——标题栏（文档名 + 条数徽章）、批注卡片（页码徽章 / 摘要 / `[待同步]` 标记 / 选中标记）、底部键位提示。**译文/解释不经过本层**（原「译文排版」组件树已删除）。
- 交互：`:keys`（`RET` / `d` / `C-c C-r` / `q` / `n` / `p`）+ `:on-press`。Host keys 位于 `emulation-mode-map-alists` 最前，**与 evil 是否启用无关**——阅读器默认在**所有面板与阅读 buffer** 里关闭 evil（`seshat-reader--disable-evil`，受 `seshat-reader-disable-evil` 控制），故不存在 evil 抢占 `:keys` 的前提；**仅当**用户把 `seshat-reader-disable-evil` 设为 nil 时才回到旧前提（evil 先启用、面板再 mount，运行期 toggle evil 需重新 mount 面板）。
- 双色板：按 `background-mode` 取内置明/暗配色，文字一律用普通 `text` + 父 Host 样式（`etaf-label` / `etaf-badge` 自带颜色会覆盖父 Host，故不用）；换主题后需重新渲染面板。
- 增量更新：状态（items / 选中项 / 文档标签）放在 `etaf-ref` 中，改 ref 由 ETAF 做 keyed patch + 行级 diff，不整树重渲染。
- 视口高度（M11.13 起）：卡片列表**不设固定高度、不做内部滚动**，改按条目数**显式计算 viewport 高度**（`seshat-reader-etaf--content-viewport-height`：chrome 6 行 + 每卡 2 行，最小 20 行）；已挂载时经 `etaf-runtime-refit` 放大视口，条目增多不被裁剪，超出面板高度的部分由**面板窗口**滚动查看。
- 降级：未安装 / `require` 抛错 / 渲染抛错三态均回退兜底渲染（细节见 [`docs/configuration.md`](configuration.md)「ETAF 渲染层」）；**降级只影响批注列表观感，译文/解释不受影响**。

**译文/解释渲染（Markdown 文本 buffer，不经 ETAF）**：

- `seshat-reader-translate--render-panel` 把 gt 在隐藏中转 buffer（` *Seshat gt*`，`:window-config` = `(display-buffer-no-window)` + `allow-no-window`）中渲染出的纯文本写入**展示 buffer**（`seshat-reader-sidebar-translate-buffer-name`），以 `gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链设视图，`truncate-lines`=nil + 显式 `word-wrap`=t，并写 `header-line`（「Seshat 译文」/「Seshat 解释」）。
- **模板链路**：`--render-panel (TEXT TITLE &optional LANGS CONTEXT)` → `seshat-reader-translate--apply-template (TEXT TITLE &optional LANGS CONTEXT)`（`format-spec` 填 `%k` 标题 / `%l` 语言对 / `%q` 原文引用块 / `%t` 正文）→ 写入只读 Markdown buffer。**模板按 `CONTEXT` 选择**：`explain` → `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`），其余（含 nil）→ `seshat-reader-translate-template`（默认 `"%l\n\n%q\n\n---\n\n%t\n"`）；两个模板**相互独立**，explain 模板为 `nil` 时不借用翻译模板。默认模板都**不含正文标题**（`%k`），标题由 `header-line` 承担。`%l` 由 `--translator` 透传的 langs 经 `--format-langs` 转成 `*en → zh*`；`%q` 由 `--quote-block` 生成、**默认开启**（`seshat-reader-translate-show-source` 默认 `t`）。`--render-object (MODE &optional TITLE LANGS CONTEXT)` 同样带可选 `LANGS` / `CONTEXT`（向后兼容）。模板非法时 `--apply-template` 回退纯正文并 `message` 警告。
- **宽度缩窄（M11.14 起）**：`--prepare-view` 末尾按 `seshat-reader-translate-visual-fill-column`（默认 `t`）启停 `visual-fill-column-mode`——软依赖、未安装时静默跳过，宽度沿用全局 `visual-fill-column-width`（`nil` → `fill-column`），关闭时显式传 `-1` 以清理窗口 margin（buffer 复用、major mode 重设后不残留缩窄）。**批注列表不启用**：ETAF 布局按 `window-body-width` 计算，`window-margins` 缩窄会导致错位。
- 键位 `q`（关面板）/ `C-c C-s`（存为批注）由 minor mode `seshat-reader-translate-panel-mode` 承载，不污染 Markdown 视图共享键位表。理由见 [`openspec/decisions.md`](../openspec/decisions.md)（ETAF 画布固定 viewport 裁剪、内容不可选中复制、CJK 2 列测量风险）。

**高度自适应（sidebar 层）**：

- 仅对 kind=`translate` 且**未挂载 ETAF runtime** 的面板生效：`seshat-reader-sidebar--fit-height-for-content` 用 `window-text-pixel-size` 换算内容行数，夹紧 `seshat-reader-sidebar-min-height`（默认 0.25）到 `seshat-reader-sidebar-max-height`（默认 0.8），成功后把实测比例写入 per-kind 高度记忆；批注列表固定用 `seshat-reader-sidebar-height`。同帧内面板增高会压缩上方阅读窗口（预期）。
- **测量口径**：`seshat-reader-sidebar--content-height` 的单行像素高取首行 `line-pixel-height` 与 `frame-char-height` 的**较小值**（Markdown 标题行通常比正文行高，直接用首行会把内容行数低估），`window-text-pixel-size` 测量上限 120 行（超长内容按上限计，避免测量耗时），再向上取整换算为行数。目标高度 = `max(1, max(min(min-h, max-h), min(max-h, content+2)))`，其中 `min-h` / `max-h` 分别是 `seshat-reader-sidebar-min-height` / `seshat-reader-sidebar-max-height` × `frame-height` 向下取整，`content` 为内容行数、`+2` 留给 header-line 与余量。

**兜底渲染**：

- 批注列表：`seshat-reader-annotation--render-list` 的纯文本 + 文本属性渲染，行携带 `id` / `page` / `queue-uuid` / `location` 属性。ETAF 已挂载时该函数**不再 `erase-buffer`**（交给渲染层增量刷新），否则随后的 `etaf-runtime-flush` 会因缓冲区被清空报 `Args out of range`。
- 译文/解释：`seshat-reader-translate--render-panel` 的 Markdown 文本 buffer 路径（见上一小节）；只有 `seshat-reader-translate-render` 取 `pop` / `pin`（或禁用面板）时回退 posframe，由 gt 的 `gt-posframe-pop-render` / `gt-posframe-pin-render` 承载。

**数据流**：`seshat-reader-annotation--refresh-list`（拉服务端批注 + 读本地队列）→ items（服务端项在前、本地待同步项在后；本地项以 `:uuid` 标识、无 `:id`）→ **全量条目**（不分页、不切片）→ 渲染层（ETAF 卡片或文本兜底；ETAF 按条目数显式计算 viewport 高度、条目增多时 `etaf-runtime-refit`）→ `seshat-reader-sidebar-show` → `display-buffer`（参数单一来源、幂等、可选光标跟随）；译文/解释的数据流为 gt → 隐藏中转 buffer → `:then` 回调 → `seshat-reader-translate--render-panel` → 同一 `sidebar-show`。

## Emacs 阅读器：展示层与渲染层（M12）

M12 把 M11 的「单个底部面板」升级为「左目录 / 右信息 / 中阅读」三栏，并把批注高亮下沉到 C 渲染层。展示层归 elisp（`seshat-reader-sidebar` / `seshat-reader-outline`），渲染层归 `render-core.c`。

**三分栏版式**：

- **用 `display-buffer-in-side-window` 而非自建 `split-window`**：显示参数为 `(side . left|right)` + `(slot . N)`。自建 `split-window` 每显示一次就重新切分主窗口，多开几次会把阅读区**逐次挤压**，关闭时又不自动回收；side window 由 Emacs 维护独立的窗口树，同侧不同 slot 互不顶替，故目录与批注可同时存在，阅读区尺寸只受两侧宽度影响。
- **per-kind 方位映射**：kind `outline` → `left`（`seshat-reader-outline-sidebar-position`，默认 `left`），kind `annotations` / `translate` → `right`（`seshat-reader-sidebar-position`，默认 `right`）；方位由单一判据 `seshat-reader-sidebar--position-for-kind` 解析，side / slot / 尺寸默认值全部由它派生。slot 由 `seshat-reader-sidebar--slot-for-kind` 按稳定 kind 顺序分配（同一 kind 恒定同 slot，显示/关闭一个 kind 不会顶掉其它 kind 的窗口）；slot 数量上限受 `window-sides-slots` 约束，超出会被 `display-buffer-in-side-window` 拒绝而回落为普通窗口。
- **尺寸语义方向化**：side 模式是**宽度**语义（`seshat-reader-sidebar-width` / `seshat-reader-outline-sidebar-width`，小数按 frame 根窗口总宽比例换算列数、整数直接作列数）；底部模式（`below-selected` / `at-bottom`）是**高度**语义（`seshat-reader-sidebar-height` 与 min/max）。per-kind 尺寸记忆因此带**方向标签**——方位在宽/高之间切换后，旧值不会按错误单位复用。

**目录面板**：

- **纯函数行模型**：`seshat-reader-outline--rows`（按 **DFS 前序**摊平成行列表，入参为树、折叠态集合、当前页）与 `--current-path`（按当前页求根→叶路径）。折叠态用**行路径**（自根到该节点的标题列表）而非标题字符串，以免同名节点互相折叠；折叠节点自身仍出行、其子树不出行。
- **渲染规则**：行首保留 outline 星号（去掉会令 `outline-regexp` 失配、TAB 折叠失效），但把星号区间设为**零宽显示**（`display ""` 只改显示、不改 buffer 文本，故 `outline-regexp` 照常匹配、`outline-hide-subtree` 仍可用）→ 每级 1 列缩进（`seshat-reader-outline--indent-width`）+ 折叠符号的 2 列，标题落在第 3/4/5 列 → `▾`/`▸` 折叠符号（无子节点用 2 空格占位对齐）→ 标题按钮 → 弹性空白 `display` 属性把页码推向右缘 → 按深度取三级 face；当前章另用 `line-prefix` 画竖线（`line-prefix` 只是显示属性、不进 buffer 文本，故不破坏 outline 结构）。
- **avy 风格跳转**：`f` 触发 `seshat-reader-outline-avy-jump`，候选为可见区带页号属性的按钮，标签由 overlay `before-string` 承载（不写 buffer 文本），`read-key` 逐键匹配，`unwind-protect` 清理标签。**零新增依赖**：不 `require` avy，只在 `avy-keys` 已绑定时复用自己的字符表，未加载时用内置表。

**装饰表（Decoration，渲染层）**：

- **数据结构**：一张 `Decoration` 表取代原来的单色 `Highlight` 表，每条带 `kind`（`DECORATION_KIND_RECT` 填充矩形 / `DECORATION_KIND_STROKE` 折线）、几何（rect 四角，或 `fz_point *pts` + `pt_count`）、`color`（RGB ∈ [0,1]）与 `alpha`。rect 与 stroke **共用一张表**，因此渲染线程只遍历一次；`width` 只对 stroke 有意义，rect 恒为 0。上限：`DECORATION_MAX_COUNT`（100000 条）、`DECORATION_MAX_ABS_COORD`（±1e6 点）、`DECORATION_MAX_POINTS`（每笔 1024 点，超出**截断而非拒绝**）、`DECORATION_MAX_STYLE_GROUPS`（64 个样式分组）。
- **为何必须改 C**：elisp 层无法在已有页面 image 上叠加半透明矩形——同一区域的 `display` 属性**互斥**（一处只有一份 `display` 规格生效），image 规格里也没有「第二个矩形」这一层。既有两个证据：M11.2b 计划记录（`openspec/completed/2026-10-12-m11.2b-reader-selection.md:25`）与 `seshat-reader-select.el` 的选区实现注释（只做文本属性、不做矩形绘制）。因此装饰在 `draw_page_thread` 内绘制。
- **绘制顺序（不变）**：在 `fz_invert_pixmap_luminance` / `fz_gamma_pixmap` **之后**、写 PNM **之前**。反色与 gamma 是整页像素变换，若在装饰之后做会连装饰一起反色；写 PNM 之后再画则进不了缓存位图，翻页回来装饰消失。
- **颜色分组与「重叠不叠深」**：rect 先扫一遍收集至多 64 组不同的 `(R,G,B,A)`，再**每组一条 `fz_path` + 一次 `fz_fill_path`**（`fz_identity` 下传，device 已持 ctm）；同组内重叠区域只被填充一次，因此多段高亮叠在一起仍是同一个透明度。越过组上限的 rect 各自单独填充（只是多几次 fill，语义不变）。
- **`ctm` 复用**：直接复用该页 rasterize 用的同一个 `fz_transform_page(dp->bbox, resolution, rotate)`，因此缩放与旋转自动对齐，不必另算变换；`rect_to_page_space` 是「Emacs rect → MuPDF 页面空间」的**唯一**换算点（被 `--text-in-rect` / `--rects-in-rect` 与绘制共用）。
- **快照深拷贝与所有权**：装饰表在派发时**快照**进 `DrawThreadArgs`（`deco` + `deco_count`），渲染线程不碰 `DocState`；快照归 job 所有，由 `free_draw_thread_args`（`draw_page_thread` 全部 7 条退出路径的唯一漏斗）经 `free_decoration_table` 释放。stroke 的点列是**堆分配**，struct 浅拷贝会让渲染线程与 `DocState` 共享 `pts`——因此快照对每条 stroke **逐条深拷贝 `pts`**；所有权规则写进 `Decoration` 结构体注释（「谁持有结构体谁释放 `pts`，且只有一份所有权」），`free_decoration_table` 是**唯一**释放路径（`--clear-highlights`、`free_doc_state`、`free_draw_thread_args` 共用），从机制上排除双 free。浅拷贝时代的 `args->hl` 裸 `free` 已替换，否则会漏掉每笔 stroke 的 `pts`。
- **elisp 侧只改表**：三个入口改表并置 `decorations_dirty`，渲染线程不参与；`--refresh-highlights` 的重绘序列不变——非 dirty 直接返回 `t`；dirty 时 `wait_for_win_jobs` → `nullify_window_cache` → `build_cache_window` → `wait_for_cached_page` → `display_cached_page`（与 `seshat-reader-dyn-redisplay-doc` 同形），故不另建渲染管线、也不与既有缓存失效逻辑分叉。
- **三个入口**（C 函数 / 注册 arity）：
  1. `--add-highlight`（`5,5`，`page x0 y0 x1 y1`）——历史入口，名字与 arity **均不变**，内部映射为「rect + 默认黄 1.0/0.85/0.0 + α 0.35」，是默认配色下的**像素级等价路径**。
  2. `--add-decoration`（`9,9`，`page x0 y0 x1 y1 r g b alpha`）——带颜色的 rect 入口；非有限颜色分量回退默认色、其余夹到 `[0,1]`。Lisp 侧在 `kind` 为 underline/strikeout 或用户改了高亮配色时走这条。
  3. `--add-stroke`（`7,7`，`page r g b alpha width points`）——折线入口，`points` 是**扁平**列表 `(x0 y0 x1 y1 …)`（逐对 `car`/`cdr` 读取并 `numberp` 守卫，超过 1024 点截断，少于 2 个点返回 nil），点数组由 C 侧 `malloc`+`memcpy` 自持。自 2026-10-25 起由 ink 轨迹渲染调用（`seshat-reader-annotation--ink-strokes-from-location` 的解析结果）。
  4. `--search-page`（`3,3`，`page needle limit`）——只读，返回该页命中矩形的列表（`fz_search_page` → `fz_rect_from_quad`，与 `--text-in-rect` 同一条 `rect_to_page_space` 换算，故命中矩形喂给装饰入口落在文字原处）。**页号 1-based**（与三个装饰入口同口径）。
  另加只读入口 `--rects-in-rect`（`5,5`，`page x0 y0 x1 y1`）——返回矩形内每个命中字符的 quad 矩形列表，与 `--text-in-rect` 共享同一份 stext 遍历（`stext_query_in_rect`），空结果返回 nil 且**不发消息**（矩形内无文本是正常答案）。这两个只读入口的页号是**历史 0-based**（服务于选区代码），与装饰/搜索入口的 1-based 并存——基数见各函数注释首段。
  另加只读入口 `--lines-in-rect`（`5,5`，`page x0 y0 x1 y1`）——**整行吸附**用：框碰到某行即返回该行**全部**字符 quad 的并集（双遍遍历，先判该行是否被碰到，命中才求并集；输出的是整行范围而非框内片段），每行一条矩形、按阅读顺序；无命中返回 nil 且**不发消息**；页号同为 **0-based**，与 `--rects-in-rect` 共享 `prepare_rect_query` 的参数校验/换算与全部消息文案。

**框选闪现（M12 补）**：

- **数据流**：`seshat-reader-select--flash-selection` 把选区矩形按 `(PAGE X0 Y0 X1 Y1)` 存进 buffer-local 的 `seshat-reader-select--flash-rects`，再调 `seshat-reader-select--redraw-highlights`——后者委托 `seshat-reader-annotation--redraw-highlights`，把**批注矩形在前、闪现矩形在后**合并成一次投喂（一次 clear + 逐条 add + 一次 refresh），因此闪现不会抹掉批注、批注重绘也不会抹掉闪现；批注模块未加载时退化为「只投闪现」。
- **timer 到点**：武装一个 `run-at-time` 定时器，到点由 `seshat-reader-select--clear-flash` 清空该 buffer 的 `--flash-rects` 并**重投一次**（批注仍在、闪现消失）；timer 指向的 buffer 已死（用户已关文档）时静默跳过。
- **buffer-local**：`--flash-timer` 与 `--flash-rects` **都是** buffer-local。两份文档几乎同时框选时，第二次 `cancel-timer` 只取消自己那份 timer，前一文档的闪现不会被「取消 + 遗留」——全局变量正是本补丁修掉的缺陷。
- **与批注高亮的关系**：闪现**不受** `seshat-reader-annotation-highlight-enabled` 约束（它是框选的即时反馈，不是批注），时长由 `seshat-reader-select-flash-duration` 决定，`<= 0` 关闭。

**跨页衔接**：

- **buffer 结构**：`[strip 行]` + `[页面 image]`。strip 是上一页底部若干像素，由页面 image spec 上的 `:slice` 裁出——`:slice` 是 **`display` 属性的包装**（`(slice X Y W H)` 与 image 同处一份 `display` 规格），不是 image 关键字，故不能当作 image plist 的键使用。
- **起点对齐**：`line-prefix` 必须由 **buffer 级 overlay** 承载（`seshat-reader--center-overlay` 覆盖整个可访问区）。若只用行内属性，strip 行与页面 image 行的前缀不一致，横向居中会差出一个前缀宽度（实测 84 px）。
- **三态落点**：向下翻页 = 「上页末行可见 + 新页顶部紧接」；向上翻页 = 落到上一页底部；`fit-to-height` 等整页操作是第三态（整页适配，不叠加 strip 偏移）。三者分别处理，不共用同一 vscroll 公式。

**防御上限**（针对不可信输入，全部在实现侧硬夹紧）：

| 对象 | 上限 | 越界行为 |
|---|---|---|
| 装饰条数 | 100000（`DECORATION_MAX_COUNT`） | 静默返回 nil，不覆盖已有条目 |
| 装饰坐标 | ±1e6 点（`DECORATION_MAX_ABS_COORD`） | 判非法、不进表（`--text-in-rect` / `--rects-in-rect` 同受此限） |
| 每笔 stroke 点数 | 1024（`DECORATION_MAX_POINTS`） | **截断**（保存前 1024 点），不拒绝整笔 |
| 装饰样式分组 | 64（`DECORATION_MAX_STYLE_GROUPS`） | 越过组上限的 rect 各自单独填充（多几次 fill，语义不变） |
| outline 标题 | 8192 字节（`OUTLINE_TITLE_MAX`） | 截断，不中断开书 |
| 批注 `location` | 64 KB、至多 2000 段 `rect:`（写入端 500 段） | 超限不解析，不影响列表渲染 |
| 搜索单页命中 | 1024（`SEARCH_PAGE_MAX_QUADS`；`limit` 另被夹到 1..10000） | 截断为前 1024 条，状态行提示「仅显示前 1024 条」 |
| 搜索整次命中 | 20000（`seshat-reader-search-max-matches`） | 达到即停止扫描并提示「命中过多」 |

## 搜索与 ink 渲染流程（2026-10-25）

两条能力的共同点：**装饰只有一个出口**——文档级装饰表 + `seshat-reader-annotation--redraw-highlights` 的全量重投。因此新增能力不新建渲染管线，只往同一次投喂里加一路几何。

### 跨页文本搜索

- **为什么整本扫描**：状态行要显示「第 i/N 个命中」，N 必须先知道；MuPDF 只给按页的 `fz_search_page`，没有文档级搜索 API。不重建文本索引是选它的理由——797 页文档整本扫描约 **1.1 秒**（`seshat-reader-search--scan` 逐页走，边界由 `seshat-reader-current-doc-pagecount` 约束）。
- **按页缓存**：`seshat-reader-search--page-results`（buffer-local 哈希，page → rect 列表）+ `seshat-reader-search--matches`（摊平后的 `(page . rect)` 序列，页号升序、页内保持 MuPDF 命中顺序，故序列确定）。跳转只移动 `--index`，不重新搜索；缓冲随 buffer 消失，无全局状态。
- **双上限**：单页由 C 侧 `SEARCH_PAGE_MAX_QUADS`（1024）硬夹紧，Lisp 侧 `--truncated-p` 判定后在状态行显式提示「仅显示前 1024 条」；总量由 `seshat-reader-search-max-matches`（默认 20000）控制，达到即停止扫描并置 `--capped`，否则一条 `.` 能扫出几十万条命中、几十 MB 常驻内存。
- **装饰共存钩子**：搜索命中不做自己的 `--clear-highlights`，而是注册 buffer-local 的 `seshat-reader-annotation-extra-decorations-function`——由 `seshat-reader-annotation--redraw-highlights` 在投喂「批注 rect → 框选闪现」之后再取当前页命中。搜索、跳转、退出都走同一次全量重投，因此三路装饰（批注 / 闪现 / 命中）永远同步，不会互相擦除。批注模块未加载时搜索降级为自投（clear → add → refresh）。
- **临时键表而非改 mode-map**：`set-transient-map` + keep 谓词（会话 active 且同一 buffer）让 `n` / `p` 只在会话存续期间表示下一个/上一个命中，退出即恢复翻页语义；把 `n` / `p` 写进 `seshat-reader-mode-map` 会永久抢掉翻页。
- **页号基数**：`--search-page` 与三个装饰入口同为 **1-based**（`resolve_page_arg` 统一校验并做唯一一次 `-1`），Lisp 侧不做换算；`--text-in-rect` / `--rects-in-rect` 保留历史 **0-based**（服务于已在页索引空间工作的选区代码）。见 `openspec/decisions.md` 的「C 侧页号基数约定」。

### ink 渲染流程（解析 → 缓存 → 投喂 stroke）

1. **解析**（纯 Lisp，零 C 依赖，可单测）：`seshat-reader-annotation--ink-strokes-from-location` 把 `location` 的每个 `ink:` 段解为 `(PAGE R G B ALPHA WIDTH POINTS TRUNCATED)`。颜色只认恰好 8 位 `#AARRGGBB`；缺颜色/宽度、非有限数、坐标个数为奇数、点数为 0 均**整笔跳过**（画歪一笔比不画更误导）；超过 1024 点截断为前 1024 点并标记 `TRUNCATED`（整笔丢弃等于用户笔迹凭空消失）。解析有界：`location` 先按 64 KB 截断。
2. **过滤与缓存**：重绘只投**当前文档**的批注（`--cached-entries` 做跨文档过滤），每页笔迹集合按 buffer 缓存（`--annotation-strokes`），避免每次重绘都重新解析整本文档。
3. **投喂**：`--add-stroke`（`page r g b alpha width points`，页号 **1-based**，`points` 为扁平 `(x0 y0 x1 y1 …)`）→ C 侧 `Decoration` 表追加 `DECORATION_KIND_STROKE` 条目（`pts` 堆分配、派发快照时逐条深拷贝）→ 渲染线程在反色/gamma **之后**、写 PNM **之前**绘制（圆头圆角），因此缩放后与页面同变换对齐。
4. **投喂顺序（唯一约定）**：`clear` → 批注 rect → 框选闪现 → 搜索命中 → **ink 笔迹** → `refresh`。ink 放在最后是因为它是唯一带 alpha 且可能很长的折线，先画不会被后画的半透明矩形叠加影响判断；顺序写进 `seshat-reader-annotation--redraw-highlights`，新增装饰路必须插进这条链而不是另起一条。
5. **失败隔离**：缺 stroke 入口（旧 `.so`）或 ink 解析失败时只跳过 ink，rect 装饰照常投喂；返回值仍只统计批注 rect 条数（ink 不进这个计数）。
6. **坐标**：ink 点与 `rect:` 同 page space（页面 pt、原点左上、y 向下），**不翻转**（数值证据见 `docs/emacs-reader.md` §5「手写轨迹显示」）。

## 数据流

- 桌面端/Android 经 WebDAV 同步文件，经 REST 同步阅读进度/批注
- 服务端 WebDAV 写操作后自动 git commit（记录来源），ETag 用工作区内容即时 blob hash
- 敏感/需本地模型任务经任务队列路由到本地处理节点，结果明文回传服务端
