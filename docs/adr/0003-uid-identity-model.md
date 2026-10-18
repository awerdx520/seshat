# ADR-003：uid 身份模型（服务端权威文件身份）

## 状态
已接受（2026-10-18）

## 背景
服务端当前以「根标签 + 相对路径」直接充当文件身份，身份随路径漂移，导致三类问题：

1. **改名/移动即失锚**。WebDAV 的 MOVE 只是一个新路径写入，服务端无「同一文件」的概念；任何改名都会让既有的阅读进度、批注、引用失去指向。
2. **三端身份互不相通**。Emacs 侧批注用 `seshat-reader-annotation--doc-id` 派生 `tag:relpath`；Android 侧用 `EpubParser.documentIdOf` 派生的 64 位内容哈希 hex；服务端落库字段是 `reading_progress.document_id` / `annotations.document_id`（单列，存的是上面两种文本之一）。同一本书在两端是两个不同的 id，服务端无法判定「说的是同一个文档」。
3. **ETag 与身份混用**。`versionedFS.ETag` 取 git blob hash，是**内容**标识而非**实体**标识：改一个字符 ETag 就变。它适合做乐观锁，但不能当身份用。

底层的困境是：路径是「位置」，内容哈希是「状态」，两者都不是「实体」。系统缺一个与位置和内容都解耦的实体标识。

## 决策
引入**服务端权威的稳定 uid**，路径与内容哈希降级为 uid 的可变属性：

1. **uid 形态**：`crypto/rand` 取 16 字节随机数，Crockford Base32（alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`，`base32.NoPadding`）编码为 26 字符，校验正则 `^[0-9A-HJKMNP-TV-Z]{26}$`。只用标准库 `crypto/rand` 与 `encoding/base32`，零新增依赖。
2. **权威登记**：新增 schema v6 表 `resources`（`uid` 主键，`UNIQUE(root, path)`），由服务端在**每次写入**时维护，客户端不生成 uid。改名只改 `path`，uid 不变；删除写 `deleted_at` 墓碑，不物理删行。
3. **状态表 v7 直接以 uid 为键重建**：迁移脚本 `DROP TABLE` 旧 `reading_progress` / `annotations`，按 uid 重新建表（`reading_progress.uid` 主键、`annotations` 带 `uid` 列与索引）。不保留 `document_id` 列、不做数据迁移。
4. **状态 API 不再接受 `document_id`，`/api/resolve?root=&path=` 为路径 → uid 唯一入口**：uid 需匹配正则，否则 400 `invalid_uid`；格式合法但未登记或已墓碑 → 404 `unknown_uid`。这是**破坏性变更**，Emacs 客户端四个模块（`annotation` / `rest` / `annotation-queue` / `translate`）在本计划内同步适配（任务 B5，双值设计：doc-id 供显示/链接、uid 供 API；`reference.el` 零改动），Android 端留给后续里程碑。

## 理由
- 只有服务端能生成全局唯一且跨端一致的标识：它同时看得见两个根、看得见所有写路径（WebDAV 双出口 + REST），是唯一的汇聚点。
- 路径与内容解耦后，改名不再破坏进度/批注/引用；`seshat:` 引用可以从「以 doc-id 文本承载身份」升级为「以 uid 承载身份」，顺带消解含 `#`/`%` 的文件名无法引用的技术债。
- **尚未部署、无存量生产数据，兼容层无收益；一次切换更简单**：保留旧列 + 映射表 + 分支解析需要长期维护两套读写路径，而它保护的存量数据为零。单次 `DROP` 重建后的读写路径只有一条，出错面更小、代码更少。
- 零新增依赖：26 字符编码只是格式化，随机源用标准库，避免为一个 id 引入 uuid/ulid 库。

## 替代方案
- **双列观察期（保留 `document_id` 列 + legacy 映射表 + 实时 `tag:path` 解析）**：**否决**。服务端未部署、无存量数据，长期维护两套读写路径（双列同填、读取回退、映射表回填、孤儿处理）成本大于收益；观察期保护的数据为零，却会延迟旧路径的清理并增加出错面。
- **内容哈希（SHA-256 / git blob）作身份**：否决。内容一改身份就变，改一个字符等于换一个文件，进度与批注仍然失锚；且大文件每次写入都要全量哈希。
- **UUID / ULID 库**：否决。为一次 16 字节随机数的格式化引入第三方依赖，与「单二进制、依赖面最小」的部署取向不符；Crockford Base32 手写编码不足 20 行。
- **自增整数 id**：否决。跨根、跨库合并时必然冲突；把既有文本 id 映射到自增整数还要额外维护一个全局序列，耦合度更高；且自增 id 会泄露库里文件总量。
- **由客户端生成并上报 uid**：否决。当前不存在离线创建文件的需求，多端生成会引入冲突消解问题；服务端生成是单点、可审计。

## 后果
- 正面：改名/移动不再失锚；三端身份收敛到同一 uid；引用、增量同步、书架共享同一个实体键；状态表结构与身份键一致，读写路径唯一。
- 负面：**破坏性变更**——状态 API 与客户端不兼容，Emacs 与 Android 都必须升级后才能正常工作（Emacs 已纳入 M7 任务 B5，Android 待后续里程碑）；`resources` 表成为必须随写路径维护的状态，钩子漏挂就会产生「有文件无 uid」的空洞。
- 风险：钩子失败是**静默**的（只记日志、不影响响应），存在事件缺失窗口；因此 registry 被定义为派生状态，必须能由文件系统 `rescan` 重建（见 ADR-004）。客户端若仍按旧 id 调用状态端点会得到 400/404，需以「升级客户端」而非「服务端兼容」应对。

## 实现要点
- **uid 生成与校验**：`internal/registry/uid.go` —— `NewUID()`（`crypto/rand` 取 16 字节 → `base32.NewEncoding(Crockford).WithPadding(NoPadding)` → 26 字符，另做长度防御性断言）与 `IsUID()`（正则 `^[0-9A-HJKMNP-TV-Z]{26}$`）。生成与校验共用同一字母表常量，保证「生成的必然通过校验、非法字符必然被拒」。零新增依赖（只用 `crypto/rand` 与 `encoding/base32`）。
- **迁移**：`internal/storage/db.go` 的 `schemaVersion` 5 → 7，`migrations` 数组只追加 v6、v7（禁改 v1–v5，`TestMigrationsLengthMatchesVersion` 守卫版本号与条数一致）。**v6** 建身份三表 `resources` / `changes` / `refs`（不动既有表，批次 A 结束即可独立验证）；**v7** 才 `DROP TABLE` 并按 uid 重建 `reading_progress` / `annotations`。两条脚本各自只执行一次。
- **v7 的机械防御**：`preMigrationChecks[7]` → `assertStateTablesEmptyBeforeRebuild`，在**同一事务内、脚本执行之前**对两表 `COUNT(*)`（表不存在时经 `sqlite_master` 判定为 0 行，`countRowsIfExists`），任一非空即中止迁移并整体回滚（`user_version` 保持原值），错误信息同时给出两表行数。用「钩子表」而非在 `applyMigration` 里写 `version == 7` 分支：后续每加一次不可逆迁移只需追加一条记录，通用迁移逻辑零改动。
- **bootstrap**：`internal/registry/bootstrap.go` 服务启动时按根遍历普通文件（跳过 `.git`、以 `.` 开头的目录、符号链接与非普通文件），`(root, path)` 未登记则生成 uid 并写 `create`；`size` + `mtime` + `blob` 均未变则跳过（`blob` 仅在 `mirror` 根且有 repo 时计算，`ondemand` 根恒为空串）。幂等可重跑；根目录本身不可读返回错误而非当成空根。
- **WebDAV 钩子**：`internal/webdav/registry.go` 的 `registryAfterWrite(rootTag, prefix, offset string, svc *registry.Service, repo *gitver.Repo, next http.Handler)` 挂在 commit 钩子内层、FTS 索引钩子外层，仅 2xx 生效（自带 statusRecorder，MKCOL / PROPPATCH 不登记）；internal 与 public 两个出口都必须挂（public 需 `path.Join(offset, rel)` 换算）。任何推导/写入失败只记日志，不影响已发出的响应。
- **REST 写与 WebDAV 写共用同一个 `registry.Apply`**：`internal/api/files.go` 在 `WriteAndCommit` / `RenameAndCommit` / `RemoveAndCommit` 之后调用 `registry.Apply`，顺序固定「落盘 → commit → registry」，`rev` 取 `repo.Head()`（尽力而为，空仓库或 commit 失败为空串）；registry 失败时文件已落盘（返回 500，由 bootstrap/rescan 补登记）。`gitver.RenameAndCommit` 与 `gitver.RemoveAndCommit` 是 M7 新增——把「移动/删除 + 提交」放进**同一个持锁临界区**，使 REST 写与 WebDAV 写不会交错出半个提交。
- **PUT 复用墓碑 uid**：`applyPut` / `resolvePutTarget` 先用 `ResolvePath`（唯一索引快路径）查存活登记，未命中再列举（含墓碑）按精确路径收敛——墓碑行被覆盖时**复用该 uid** 并发 `update`，由 `registry.Apply` 归一为 create 并清除墓碑。既避开 `UNIQUE(root, path)` 冲突，也让「删了又建」保持同一身份。
- **Emacs 改造（任务 B5，双值设计）**：`doc-id` 只用于显示与 `seshat:` 链接文本，`uid` 只用于 API 身份。① `seshat-reader-annotation.el` 新增 `--uid`（路径 → `/api/resolve` → uid，按 `file-truename` 内存缓存 `seshat-reader-annotation--uid-cache`，失败 `user-error`），`--doc-id` 不变；列表 buffer 拆分两个 buffer-local（`seshat-reader-annotation-list-document-id` 存 doc-id 供链接、`seshat-reader-annotation-list-uid` 存 uid 供刷新/删除）。② `seshat-rest.el` 四个进度/批注函数参数改 `uid`，JSON 字段与 query 参数同步改。③ `seshat-reader-annotation-queue.el` 的 entry 增加 `:uid`，同步用 `:uid`，缺 `:uid` 的旧条目跳过并提示。④ `seshat-reader-translate.el` 的存批注调用点必须改用 `--uid`（否则 doc-id 被当 uid 发送）。⑤ `seshat-reader-reference.el` **零代码改动**（链接身份仍由 doc-id 文本承载）。
- **REST 契约**：`GET /api/resources`、`/api/resources/{uid}`、`/api/resolve`、`/api/roots`、`/api/files/{path...}`、`/api/refs`、`/api/changes`、`/api/resources/rescan` 等，详见 [`docs/api.md`](../api.md) 与 [`docs/sync-protocol.md`](../sync-protocol.md)。

### 实现落点

| 关注点 | 文件 |
|---|---|
| uid 生成 / 校验 | `internal/registry/uid.go` |
| v6 / v7 迁移、v7 前置检查 | `internal/storage/db.go`（`migrations`、`preMigrationChecks`） |
| 事件应用（`resources` + `changes` 同事务） | `internal/registry/service.go`（`Apply`）→ `internal/storage/apply.go`（`ApplyResourceChange`） |
| 身份登记读写 | `internal/storage/resource.go`、`internal/storage/change.go`、`internal/storage/ref.go` |
| bootstrap / rescan | `internal/registry/bootstrap.go`、`internal/api/rescan.go` |
| WebDAV 写钩子 | `internal/webdav/registry.go` |
| REST 写路径（落盘 → commit → registry） | `internal/api/files.go`、`internal/gitver/version.go`（`RenameAndCommit` / `RemoveAndCommit`） |
| 状态端点 uid 校验（400 / 404 分流） | `internal/api/server.go`（`requireKnownUID`）、`internal/storage/state.go` |
| 错误码与 HTTP 映射 | `internal/logging/errors.go`、`internal/api/server.go`（`statusForCode`） |
| Emacs 双值改造 | `emacs/seshat-reader/seshat-reader-annotation.el`、`emacs/seshat-rest.el`、`emacs/seshat-reader/seshat-reader-annotation-queue.el`、`emacs/seshat-reader/seshat-reader-translate.el` |

## 相关决策
- `openspec/decisions.md` 2026-10-18 第 1 条（uid 身份：直接切换，无兼容层）。
- `openspec/decisions.md` 2026-10-18 第 2 条（增量同步游标）。
- `openspec/decisions.md` 2026-10-18 第 3 条（多根映射与 REST 写）。
- [ADR-004：增量变更日志与游标](0004-incremental-change-log.md)。
