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

**与批注 `location` 的同构关系**：批注的 `location` 形如 `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（页码 1-based、页面坐标），链接片段**直接复用同一字符串**，不新增解析器。批注列表的行携带该字符串（文本属性），故「批注 → 引用」取值不触网；`page:` 段直接传给 `seshat-reader-goto-page`，`rect:` 段当前仅做格式校验（无高亮承载）。

**双形态（M7 起）**：`<target>` 可以是 **uid**（服务端权威身份，如 `seshat:01J8ZK4Q7M2X9VYB3TR6NDW5PC#page:3`）或 **doc-id 文本**（`tag:path` 或纯 path，人可读、可手写）。服务端解析优先级为 **uid → `tag:path` → 纯 path（默认根）**（`registry.Resolve`）：uid 形态跨改名稳定，doc-id 形态在改名后失效，需重新构造。含 `#`/`%` 的非法 target 仍按上述规则拒绝。

**refs 表由写路径维护**：`.org` 写入成功后，服务端解析全文 `seshat:` 链接并用 `registry.RefreshRefs` **整份替换**该源的全部引用（先删后插、单事务）；文件被删除或从 `.org` 改成其它扩展名时清空（`ClearRefs`）。目标解析不到只跳过该条（链接可以指向尚未同步的文档），故 `refs` 是**尽力而为**的派生数据，解析失败不阻塞写响应。查询走 `GET /api/refs?uid=&direction=in|out`。

**Emacs 侧的双值分工**：`seshat-reader-annotation--uid`（路径 → `GET /api/resolve` → uid，`file-truename` 内存缓存）只用于状态 API；`seshat-reader-annotation--doc-id`（文件 → `tag:path`）仍用于显示与链接文本。二者分别落在列表 buffer 的 `seshat-reader-annotation-list-uid` 与 `seshat-reader-annotation-list-document-id`；`seshat-reader-reference.el` **零改动**——链接身份仍由 doc-id 文本承载，uid 只是 API 身份。

## 阅读器面板分层（M11.7–M11.10）

面板分为「承载层 / 批注渲染层（ETAF，可选）/ 兜底渲染」三层，另有一条独立的**译文/解释 Markdown 文本 buffer 路径**（不经 ETAF）。

**承载层 `seshat-reader-sidebar`（零依赖）**：

- **pop 式底部弹出**：`seshat-reader-sidebar-position` 取 `below-selected`（当前窗口下方分割，形如 `*Help*`）或 `at-bottom`（frame 底部整宽）。同一时刻只有一个面板窗口，批注与译文**后显示者接管**。
- **必须经 `display-buffer`**：首次显示、gt 的 `:window-config`、popper 重开三条路径都走 `display-buffer`，以保证**幂等**（同 buffer 同 kind 重复显示只复用窗口、不重建）；面板参数由 `seshat-reader-sidebar--display-params` **单一来源**生成。
- **`display-buffer-overriding-action`**：显示时用它包住 action list，使本包布局优先于 popper 在 `display-buffer-alist` 表头插入的规则；popper 重开（裸 `display-buffer`）时改由 `seshat-reader-sidebar-display-buffer` 分流回本包逻辑，故两条路径布局一致。
- **per-kind 高度记忆**：`seshat-reader-sidebar--state` 为内存 alist（零依赖）；切换内容前先捕获当前窗口高度（比例）存给其 kind，再用目标 kind 记住的高度新建窗口。仅会话内有效，不持久化。
- **禁用 `window-toggle-side-windows`**：它是 frame 级全量开关（会连带删除/恢复 eca-chat、which-key 的侧窗），toggle 只对本包面板窗口做 `delete-window`。

**渲染层 `seshat-reader-etaf`（可选，依赖 `etaf-ui`；只负责批注卡片）**：

- 职责（M11.10 起）：**仅渲染批注卡片列表**——标题栏（文档名 + 条数徽章）、批注卡片（页码徽章 / 摘要 / `[待同步]` 标记 / 选中标记）、底部键位提示。**译文/解释不经过本层**（原「译文排版」组件树已删除）。
- 交互：`:keys`（`RET` / `d` / `C-c C-r` / `q` / `n` / `p`）+ `:on-press`。Host keys 位于 `emulation-mode-map-alists` 最前，evil 不会吃掉——**但依赖加载顺序**：evil 先启用、面板再 mount 才成立；运行期 toggle evil 需重新 mount 面板。
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

## 数据流

- 桌面端/Android 经 WebDAV 同步文件，经 REST 同步阅读进度/批注
- 服务端 WebDAV 写操作后自动 git commit（记录来源），ETag 用工作区内容即时 blob hash
- 敏感/需本地模型任务经任务队列路由到本地处理节点，结果明文回传服务端
