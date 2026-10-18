# ADR-004：增量变更日志与全局游标

## 状态
已接受（2026-10-18）

## 背景
WebDAV 协议本身**没有变更流**：它只提供「列目录 + 逐个读 ETag/属性」。客户端想知道「自上次同步以来哪些文件变了」，只能用 `PROPFIND` 全量遍历再比对本地记录——笔记根尚可接受，电子书库（大文件、多根）不可接受。

同时，uid 身份模型（ADR-003）落地后，客户端需要「按身份取增量」而非「按路径猜增量」：改名与删除必须能被感知。删除尤其关键——全量遍历只能发现「本地有、远端无」，但无法区分「远端删了」与「远端临时不可达」。

跨根场景还要求单一游标：客户端持有 `notes` 与 `ebooks` 两个根时，两个独立序列会让「一起同步」变成两套进度状态。

## 决策
引入**全局单调变更日志 + 客户端游标**：

1. **全局 `seq`**：新增 schema v6 表 `changes`，主键 `seq INTEGER PRIMARY KEY AUTOINCREMENT`，跨全部根共用一个序列，单调递增且不复用。客户端只持有一个 `cursor`（最后消费的 seq）。
2. **事件四类**：`op` 取值固定为 `create` / `update` / `rename` / `delete`；`rename` 携带 `old_path`，`delete` 的 `path` 保留删除前路径。
3. **墓碑语义**：删除不物理删 `resources` 行，而置 `deleted_at`（RFC3339）并追加 `delete` 事件；`GET /api/resources/{uid}` 对墓碑返回 404，`?include_deleted=true` 可见。
4. **增量消费**：`GET /api/changes?since=<cursor>&limit=` 返回 `{changes, next_cursor, has_more}`；`limit` 默认 500、最大 2000。客户端用 `next_cursor` 覆盖本地 cursor，`has_more=true` 时立即再拉一轮。
5. **registry 是派生状态**：`resources` + `changes` 可由文件系统全量重扫（`POST /api/resources/rescan`）重建；`changes` 不设 TTL。
6. **目录批量**：目录级 MOVE / DELETE 按 `path = ? OR path LIKE ? || '/%'` 匹配存活资源，在**同一事务**内逐条写事件，避免「一半有事件一半没有」的中间态。

## 理由
- 单写者 SQLite 下，`AUTOINCREMENT` 给出的单调序列是**最简单且最可靠**的游标基准：不需要向量时钟、不需要每根独立计数、不需要客户端合并。
- 跨根统一序列让客户端同步器只需一个 int 状态，与「一个同步循环处理所有根」的实现方式天然对齐。
- 墓碑而非硬删，是客户端能区分「删除」与「暂时不可达」的前提；`changes` 无 TTL 则保证长期离线的客户端回来时仍能补齐（单用户数据量级下增长可忽略）。
- 把 registry 定义为派生状态，使「钩子失败导致事件缺失」变成**可修复**问题而非数据损坏——rescan 是兜底而不是日常路径。

## 替代方案
- **每根独立 seq**：否决。客户端需要维护多个游标且必须原子地一起推进，否则跨根一致性无从判断；服务端也要为每根维护计数器。
- **文件 mtime 扫描（PROPFIND 比对）**：否决。这是现状做法的延续，会漏掉删除（未知路径无从遍历）与改名（只能看成删+增，uid 会断），且大库遍历成本随文件数线性增长。
- **git log 当变更流**：否决。git 记录的是内容历史而非实体历史，无法表达 uid、无法表达「删除但保留身份」，也拿不到 `if-match` 冲突语义；何况电子书库根不进 git。
- **SQLite `UPDATE` 钩子 + `rowid` 隐式序列**：否决。`rowid` 在 vacuum 或最大 rowid 行被删后可能复用，不满足「不复用」这一游标不变量。

## 后果
- 正面：客户端同步从 O(全库) 降为 O(增量)；删除与改名可感知；跨根单游标；事件缺失可由 rescan 修复。
- 负面：`changes` 表单调增长（无 TTL），长期需考虑归档或压缩策略；每个写路径都必须保证「落盘 → commit → registry」的顺序，顺序颠倒会让事件带错的 `rev`。
- 风险：钩子失败窗口内的事件永久缺失（不自动补），必须依赖 rescan 兜底，因此 rescan 的正确性与幂等性是一等要求；DB 单连接（`SetMaxOpenConns(1)`）下 registry 事务内不得做文件哈希等长耗时 IO，否则会阻塞整个服务。

## 实现要点
- **表结构**：见计划设计 1 的 `changes` 定义（含 `idx_changes_uid`）。`resources` / `changes` / `refs` 三表同属 **v6** 单条迁移；状态表 `reading_progress` / `annotations` 的 uid 重建属 **v7**（任务 B4）。v6 不改动任何既有表，故批次 A 可独立交付验证。
- **`changes.seq` 与分页实现**：`internal/storage/change.go` —— `AppendChange`（单条追加，返回新 `seq`）、`ListChanges(since, limit)`、`LatestChangeSeq`。分页语义：**实际按 `limit+1` 条查询**（`SELECT … WHERE seq > ? ORDER BY seq ASC LIMIT ?`），`len(items) > limit` 即 `has_more=true` 并裁掉多取的那条；`next_cursor` 取本批最后一条的 `seq`，**空批次时回传入参 `since`**（游标不倒退，重试安全）。`limit <= 0` 取默认 500、`> 2000` 夹紧为 2000、`since < 0` 归零；返回空切片而非 nil（避免序列化出 JSON `null`）。
- **写入与顺序**：`registry.Service.Apply(Event)` 委托 `storage.ApplyResourceChange`，在**单事务**内 upsert `resources` + `AppendChange`。WebDAV 与 REST 写共用同一个 `Apply`，顺序固定「落盘 → commit → registry」；`rev` 取 `Repo.Head()`（**尽力而为**：repo 为 nil、空仓库或 commit 失败时为空串，客户端不得据此判断同步状态）。
- **bootstrap / rescan 的事件语义**：`internal/registry/bootstrap.go` 的 `Bootstrap` 由启动期调用，对「磁盘上有、登记表无」的文件生成 uid 并写 **`create`** 事件（`size`/`mtime`/`blob` 未变则 `unchanged`、不产生事件，客户端游标不推进）；`Rescan` = `Bootstrap` + 「登记中存活但本次未遍历到」写墓碑与 `delete` 事件。
- **目录批量事件**：`internal/webdav/registry.go` —— 按请求方法分发（`PUT` → `applyPut`、`DELETE` → `applyDelete`、`MOVE` → `applyMove`、`COPY` → `applyCopy`，MKCOL/PROPPATCH 不登记）。`applyDelete` 对文件或目录统一按「自身或子树」列举存活登记，逐条写墓碑与 `delete` 事件（已墓碑行跳过，不重复记事件）；目录级 MOVE 同样整棵子树逐条写 `rename`（`old_path` 记旧路径）。REST 侧 `internal/api/files.go` 的 DELETE 与 `POST /api/resources/{uid}/move` 复用同一套列举 + 逐条 `Apply`（move 走 `OpRename` 并带 `OldPath`）。
- **并发**：SQLite 单连接（`SetMaxOpenConns(1)`）串行化写登记表，服务端无需额外锁；rescan 的独占性由 `internal/api/rescan.go` 的 `Server.rescanRunning`（`atomic.Bool`）**CAS 抢占**保证——抢不到立即返回 `409 rescan_in_progress`（**不排队**：维护端点等待会掩盖调用方的误用），`defer` 归还独占权，客户端断开经 `r.Context()` 取消遍历。registry 事务内不得做文件哈希等长耗时 IO。
- **API**：`GET /api/changes?since=&limit=` → `{changes, next_cursor, has_more}`；端点细节见 [`docs/api.md`](../api.md) §9，客户端实现见 [`docs/sync-protocol.md`](../sync-protocol.md) §4。

### 实现落点

| 关注点 | 文件 |
|---|---|
| `changes` 表与 v6 迁移 | `internal/storage/db.go` |
| `AppendChange` / `ListChanges` / `LatestChangeSeq` | `internal/storage/change.go` |
| 事务内 upsert `resources` + append `changes` | `internal/storage/apply.go`（`ApplyResourceChange`） |
| 事件编排与 `rev` 取值 | `internal/registry/service.go`（`Apply`） |
| bootstrap（`create` 事件）/ rescan | `internal/registry/bootstrap.go` |
| 目录批量事件、WebDAV 写登记 | `internal/webdav/registry.go`（`applyDelete` / `applyPut`） |
| rescan 端点与 CAS 抢占 | `internal/api/rescan.go` |
| 变更流端点 | `internal/api/resources.go`、`internal/api/server.go` |

## 相关决策
- `openspec/decisions.md` 2026-10-18 第 2 条（全局 `changes.seq` 游标、墓碑、rescan 重建）。
- `openspec/decisions.md` 2026-10-18 第 3 条（多根映射；书库根只经 REST，事件同样登记）。
- [ADR-003：uid 身份模型](0003-uid-identity-model.md)。
