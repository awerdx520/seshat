# M7 服务端地基：uid 身份 · 引用 · 增量同步

## 当前状态

- 阶段：Phase 4（Review & Document）· 完成
- 已确认：方案 ✅（2026-10-18，含「取消兼容期」「Emacs 四模块双值」两次修订）、计划 ✅（2026-10-18）
- 独立审查：首轮 ❌ → 修订 → 二轮 ❌ → 修订 → 三轮 ✅ 通过
- 执行：批次 A（A1–A7）、B（B1–B7）、C（C1–C4）全部完成
- 验证：Go `go test ./...` 13 包全绿（含 `-race`）；Emacs ERT 6 套件 181 例 0 unexpected / 0 skipped；端到端 A 11 步 + B 6 项全 PASS
- 归档：本文件已移入 `openspec/completed/`

## 目标

把「文件身份 = 路径」改为「服务端权威的稳定 uid」，并补上变更日志与引用图，为 M8（Emacs REST 同步）、M9.2（Android 数据源）、M10（Reader 书架）提供共同地基。

可机械判定的验收标准：

1. 服务端为每个普通文件分配跨改名稳定的 uid，`resources` 表为权威登记（改名后 uid 不变）。
2. 所有 WebDAV 写（internal 与 public 两个出口）与 REST 写都产生一条带全局单调 seq 的变更事件。
3. 状态 API 直接以 uid 为键（无兼容层、不接受 `document_id`）；Emacs 端四模块（`annotation` / `rest` / `annotation-queue` / `translate`）同步适配，交付后批注与进度立即可用。
4. `seshat:` 引用可解析为 uid，`refs` 表支持双向查询。
5. L1 `go build ./... && go vet ./...` exit 0；L2 `go test ./...` 全绿且新增用例 ≥40；L3 curl 脚本端到端通过。

## 根本问题与假设

**根本问题**：三端要围绕同一批文件协作，但服务端的文件身份是**路径**——WebDAV 的 MOVE 只是写了新路径，git blob hash 是内容标识而非实体标识；Emacs 写 `<tag>:<relpath>`、Android 写 64 位内容哈希、服务端存不透明文本，三套身份互不相通。后果是改名即失锚、跨端批注无法归并，且无从得知「自上次同步以来什么变了」。

| # | 假设 | 来源 | 验证方式 |
|---|---|---|---|
| H1 | 服务端是唯一能生成全局一致 uid 的位置（它看得见所有写路径与所有根） | 事实✓（roadmap 决策 8：服务端权威） | A4/A6 后「WebDAV 双出口与 REST 写落到同一 uid」 |
| H2 | 笔记根与书库根可在同一进程内统一登记，书库无需 WebDAV 入口 | 事实✓（roadmap 决策 5：电子书按需）+ 假设?（书库无外部 WebDAV 写入需求） | B2 双根 bootstrap + B3 书库写 403 |
| H3 | 全局 `seq` + 客户端单游标足以表达跨根增量 | 类比⚡（Syncthing / Dropbox journal 的 journal 游标） | A2 分页测试 + A7 游标连续性断言 |
| H4 | 单写者 SQLite（`SetMaxOpenConns(1)`）足以串行化 registry 事务，无需额外锁 | 事实✓（`internal/storage/db.go` `Open`） | A2 并发写测试 |
| H5 | WebDAV 目录级 MOVE/DELETE 可在响应后用 `path` 前缀在 registry 内批量处理（无需 pre-hook） | 事实✓（resources 记录保留至墓碑） | A4 目录 MOVE/DELETE 用例 |
| H6 | Emacs「doc-id 用于显示与链接文本、uid 用于 API」的双值设计不破坏既有引用模块 | 假设?（`seshat-reader-reference.el:405` 只读 `seshat-reader-annotation-list-document-id` 做格式化） | B5 的 `seshat-reader-reference-test` 全绿 + 列表 buffer 同时持有 doc-id/uid 两值 |
| H7 | 服务端尚未部署、状态表无存量数据，`DROP TABLE` 重建无数据损失 | 用户显式（2026-10-18 裁决） | B4 迁移前 `COUNT(*)` 防御性断言 |

## 设计

### 1. 数据模型（schema v6 + v7）

服务端 `internal/storage/db.go` 的 `schemaVersion` 由 5 升到 7，分两条迁移脚本（只追加、不改既有脚本）：

- **v6（任务 A1）**：新建身份三表 `resources` / `changes` / `refs`。此版本不改动任何既有表，批次 A 交付时状态表仍按原样工作。
- **v7（任务 B4）**：重建状态表 `reading_progress` / `annotations` 为 uid 键。与 v6 分开，使「身份登记」与「状态 API 破坏性切换」各自成为可独立验证的交付点。

**v6 脚本**：

```sql
-- 资源登记表：服务端权威文件身份
CREATE TABLE IF NOT EXISTS resources (
  uid        TEXT PRIMARY KEY,
  root       TEXT NOT NULL,
  path       TEXT NOT NULL,
  kind       TEXT NOT NULL DEFAULT 'file',
  blob       TEXT NOT NULL DEFAULT '',
  size       INTEGER NOT NULL DEFAULT 0,
  mtime      INTEGER NOT NULL DEFAULT 0,
  rev        TEXT NOT NULL DEFAULT '',
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL,
  deleted_at TEXT,
  UNIQUE(root, path)
);
CREATE INDEX IF NOT EXISTS idx_resources_blob ON resources(blob);

-- 变更日志：全局单调游标
CREATE TABLE IF NOT EXISTS changes (
  seq        INTEGER PRIMARY KEY AUTOINCREMENT,
  uid        TEXT NOT NULL,
  op         TEXT NOT NULL,
  root       TEXT NOT NULL,
  path       TEXT NOT NULL,
  old_path   TEXT NOT NULL DEFAULT '',
  blob       TEXT NOT NULL DEFAULT '',
  rev        TEXT NOT NULL DEFAULT '',
  changed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_changes_uid ON changes(uid);

-- 引用图
CREATE TABLE IF NOT EXISTS refs (
  source_uid      TEXT NOT NULL,
  source_location TEXT NOT NULL DEFAULT '',
  target_uid      TEXT NOT NULL,
  target_location TEXT NOT NULL DEFAULT '',
  created_at      TEXT NOT NULL,
  PRIMARY KEY (source_uid, source_location, target_uid, target_location)
);
CREATE INDEX IF NOT EXISTS idx_refs_target ON refs(target_uid);
```

**v7 脚本**（重建状态表；因无存量数据，无需数据搬迁）：

```sql
-- 状态表直接以 uid 为键（M7 前尚未部署，无存量数据，故重建）
DROP TABLE IF EXISTS reading_progress;
CREATE TABLE IF NOT EXISTS reading_progress (
  uid        TEXT PRIMARY KEY,
  position   TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
DROP TABLE IF EXISTS annotations;
CREATE TABLE IF NOT EXISTS annotations (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  uid        TEXT NOT NULL,
  location   TEXT NOT NULL,
  text       TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_annotations_uid ON annotations(uid);
```

**为何 DROP 旧表**：M7 开工时服务端尚未部署，`reading_progress` / `annotations` 无生产数据；保留 `document_id` 需长期维护两套读写路径，收益为零。v7 与 v6 分开落地，使批次 A（身份与事件）不触碰状态表、批次 B 一次性完成「表重建 + API + Emacs 切换」。两条脚本均只执行一次；`migrations` 数组只追加。

`op` 取值固定为 `create` / `update` / `rename` / `delete`。删除写墓碑（`resources.deleted_at` 置 RFC3339）并追加 `delete` 事件（`path` 保留删除前路径）；`changes` 不设 TTL。

### 2. uid 形态

- 生成：`crypto/rand` 取 16 字节 → Crockford Base32（alphabet `0123456789ABCDEFGHJKMNPQRSTVWXYZ`，`base32.NoPadding`）→ 26 字符，例 `01K8Q3M7D2X9V6T1B8N5C0RDEF`。
- 校验：正则 `^[0-9A-HJKMNP-TV-Z]{26}$`。
- **零新增依赖**（只用标准库 `crypto/rand` / `encoding/base32`）；客户端不生成 uid（离线创建需求当前不存在）。

### 3. 事件与游标

- `changes.seq` 由 `INTEGER PRIMARY KEY AUTOINCREMENT` 提供，保证单调递增且不复用。
- 客户端持有 `cursor`（最后消费的 seq），`GET /api/changes?since=<cursor>` 返回增量；响应含 `next_cursor` 与 `has_more`。
- 目录级 MOVE / DELETE 按 `path = ? OR path LIKE ? || '/%'` 匹配存活资源，在同一事务内逐条写事件。
- `rev` 取 commit 后的 `Repo.Head()`（新增方法），**尽力而为**：commit 失败或空仓库时为空串。

### 4. 根映射

```yaml
webdav:
  root: "./data/seshat"        # 向后兼容：等价 roots[0]
  roots:                        # 未配置时等价单根 tag=notes
    - { tag: notes,  path: "./data/seshat" }
    - { tag: ebooks, path: "./data/ebooks" }
```

- `roots[0]` = 笔记根：WebDAV `/dav/` 全量镜像 + FTS 索引 + git 版本化（现状不变）。
- `roots[1..]` = 书库根：**不挂 WebDAV**，只经 REST 按需读取（契合路线图决策 5），登记与 changes 同样记录，**不进 FTS 索引**。
- tag 必须唯一且非空；未配置 `roots` 时使用内置单根（tag=`notes`, path=`webdav.root`）。
- `GET /api/roots` 下发根清单（不含绝对物理路径的敏感信息，只回 tag 与逻辑前缀；物理路径仅在服务端日志出现）。

### 5. 写路径与钩子顺序

WebDAV 钩子链（外层 → 内层，后置钩子按内层先执行）：

```
authenticator.Middleware(
  indexAfterWrite(...)             // 最后：FTS 索引
    └ registryAfterWrite(...)      // 其次：事件登记（自带 statusRecorder）
        └ commitAfterWrite(...)    // 最先：git commit
            └ newDAVHandler(...)
)
```

- `registryAfterWrite(rootTag, prefix, offset string, svc *registry.Service, repo *gitver.Repo, next http.Handler) http.Handler`：仅当响应 2xx 时处理（自带 `statusRecorder`）；`rev` 取 `repo.Head()`；失败只记日志，不影响响应。
- **internal 与 public 两个出口都要挂**（public 是笔记根的子目录，`root` 同为 `notes`，`path = path.Join(offset, rel)`），使第三方 WebDAV 写入同样进 registry。
- 方法映射：PUT 新建 → `create`（生成 uid）；PUT 覆盖 → `update`；MOVE 文件 → `rename`（uid 不变、`old_path` 记旧路径）；MOVE 目录 → 前缀批量 `rename`；DELETE 文件/目录 → 前缀批量墓碑 + `delete`；COPY → 目标新 uid + `create`；MKCOL/PROPPATCH 不登记。
- REST 写与 WebDAV 写共用同一个 `registry.Service.Apply`，顺序固定「落盘 → commit → registry」。
- 新增 `Repo.Head() (string, error)`（持锁；空仓库返回 `""` 且 `nil` error）。**不改 `Commit` 签名**（测试有约 15 处调用）。

### 6. REST 契约

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/resources?root=&prefix=&since=&include_deleted=` | 登记清单 |
| GET | `/api/resources/{uid}` | 单资源元数据（墓碑返回 404） |
| GET | `/api/resolve?root=&path=` | 路径 → uid（未登记 404） |
| GET | `/api/changes?since=<seq>&limit=` | `{changes, next_cursor, has_more}`；limit 默认 500、最大 2000 |
| GET | `/api/roots` | 根映射下发 |
| GET | `/api/files/{path...}` | 读内容（书库按需下载；支持 Range） |
| PUT | `/api/files/{path...}` | 写内容：`If-Match` ETag 更新 / `If-None-Match: *` 创建；冲突 412 |
| DELETE | `/api/files/{path...}` | 删除 |
| POST | `/api/resources/{uid}/move` | body `{"to":"new/path"}`；uid 定位，避免 Go 1.22 路由限制（见下） |
| GET | `/api/refs?uid=&direction=in\|out` | 引用双向查询 |
| POST | `/api/resources/rescan` | 显式重扫（维护用，返回 Stats） |

**路由约束**：Go 1.22 `ServeMux` 不允许 `{path...}` 通配段之后再有字面量段（注册 `POST /api/files/{path...}/move` 会 panic："wildcard not at end"；既有 `versions` 端点已踩过同类限制，见 `internal/api/server.go` 注释）。因此移动操作以 uid 定位：`POST /api/resources/{uid}/move`，body 携带目标路径。

**状态端点直接以 uid 为键**：`GET|PUT /api/progress/{uid}`、`GET /api/annotations?uid=`、`PUT|DELETE /api/annotations/{id}`（不变）。uid 必须匹配 `^[0-9A-HJKMNP-TV-Z]{26}$`，否则 400 `invalid_uid`；格式合法但未登记或已墓碑 → 404 `unknown_uid`。`/api/resolve?root=&path=` 是客户端获取 uid 的唯一入口（不提供按旧 `document_id` 解析）。**这是破坏性变更**：CHANGELOG 需标注，Emacs 端由任务 B5 同步改造，Android 端留给 M9.2 后续里程碑。

### 7. 状态表重建与客户端切换

1. **v7 重建**：`DROP TABLE` 旧 `reading_progress` / `annotations` 后按 uid 重建（见设计 1，任务 B4 落地）。无数据迁移、无孤儿处理。
2. **Emacs 切换（任务 B5，双值设计）**：`doc-id`（`tag:relpath`）只用于显示与 `seshat:` 链接文本，`uid` 只用于 API 身份。新增 `seshat-reader-annotation--uid`（路径 → `GET /api/resolve` → uid，按 `file-truename` 内存缓存，失败 `user-error`），`--doc-id` 保持不变；列表 buffer 同时持有 `list-document-id`（doc-id，供链接）与 `list-uid`（uid，供刷新/删除）两个 buffer-local。`seshat-rest.el` 四个进度/批注函数参数改 `uid`（JSON 字段与 query 参数同步改名）。`seshat-reader-annotation-queue.el` 的 entry 增加 `:uid`。`seshat-reader-translate.el` 的存批注调用点改用 `--uid`（必须改代码）。`seshat-reader-reference.el` 零改动（只读 doc-id）。
3. **Android**：不在本计划范围；M9.2 数据源接入时直接按 uid 设计（不产生 legacy 数据）。

### 8. 引用（refs）

- `seshat:` 链接支持双形态：`seshat:<uid>#<location>`（新）与 `seshat:<doc-id>#<location>`（既有）。
- `.org` 写入成功（2xx）后解析其内容中的 `seshat:` 链接 → `registry.Resolve` → `refs.ReplaceRefs(sourceUID, ...)`（同一事务先删后插）。
- `GET /api/refs?uid=&direction=in|out` 支持双向查询。
- uid 形态顺带消除 tech-debt「含 `#`/`%` 的文档名不支持引用」。

## 任务

### 批次 A：身份与事件（可独立验证）

- [x] A1 schema v6 迁移与表级 CRUD（依赖：无）
  - 文件：`internal/storage/db.go`（改）、`internal/storage/resource.go`（新）、`internal/storage/change.go`（新）、`internal/storage/ref.go`（新）、`internal/storage/resource_test.go`（新）、`internal/storage/change_test.go`（新）
  - 步骤：① **先写测试并见红**（迁移后 `user_version=6`、三张新表存在（`resources` / `changes` / `refs`）、`UNIQUE(root,path)` 生效、`changes.seq` 单调、墓碑后按 uid 查仍可得）；② `db.go` 追加 v6 脚本（仅身份三表，**不含状态表变更**；SQL 见设计 1）；③ 实现表级方法：`CreateResource` / `UpsertResource` / `GetResourceByUID` / `GetResourceByPath` / `ListResources` / `TombstoneResource` / `RenameResource` / `AppendChange` / `ListChanges` / `ReplaceRefs` / `ListRefs`
  - 验收：`go test ./internal/storage/...` 全绿，新增用例 ≥14；并确认 `state.go` 与 `state_test.go` 未被改动（状态表在 B4 的 v7 处理）
- [x] A2 registry 包（依赖：A1）
  - 文件：`internal/registry/uid.go`、`service.go`、`bootstrap.go`（均新）、`uid_test.go`、`service_test.go`、`bootstrap_test.go`（均新）
  - 步骤：① 测试先行；② `uid.go`：`NewUID() (string, error)` / `IsUID(string) bool`；③ `service.go`：`New(db, repo)`、`Apply(Event) error`（单事务：upsert resources + append change）、`Resolve(key string) (string, error)`（接受 uid / `tag:path` / 纯 path，后两种查 `resources` 登记）、`ResolvePath(root, path)`、`Entry(uid)`、`List(filter)`、`Changes(since, limit)`；④ `bootstrap.go`：`Bootstrap(ctx, roots) (Stats, error)` 与 `Rescan`，`Stats{Scanned, Created, Updated, Unchanged, Failed}`；⑤ 目录批量事件辅助函数
  - 验收：`go test ./internal/registry/...` 全绿，新增用例 ≥16
- [x] A3 `gitver.Head`（依赖：无）
  - 文件：`internal/gitver/version.go`（改）、`internal/gitver/version_test.go`（改）
  - 步骤：新增 `func (r *Repo) Head() (string, error)`（持锁；空仓库 `""`/nil）；不改 `Commit`/`WriteAndCommit` 签名；补 2 例测试
  - 验收：`go test ./internal/gitver/...`
- [x] A4 WebDAV registry 钩子（依赖：A2、A3）
  - 文件：`internal/webdav/versioned.go`（改）、`internal/webdav/policy.go`（改）、`internal/webdav/registry_test.go`（新）
  - 步骤：① 实现 `registryAfterWrite(rootTag, prefix, offset string, svc *registry.Service, repo *gitver.Repo, next http.Handler) http.Handler`（2xx 判定 + 方法映射 + 失败仅日志）；② 新增入口 `VersionedHandlerWithRegistry` 与 `NewPolicyVersionedHandlerWithRegistry`（**保留既有函数签名不变**）；③ 链顺序见设计 5；④ 测试：PUT/MOVE/DELETE/COPY 产生事件、4xx 不产生、目录 MOVE/DELETE 批量、public 出口 offset 换算
  - 验收：`go test ./internal/webdav/...` 全绿，新增用例 ≥8
- [x] A5 api 读端点（依赖：A2）
  - 文件：`internal/api/resources.go`（新）、`internal/api/server.go`（改）、`internal/api/resources_test.go`（新）
  - 步骤：① `Server` 增加 `registry *registry.Service` 字段；② 新增构造函数 `NewHandlerFullWithRegistry(db, repo, indexer, reg, a, nodeAuth)`（旧构造函数保留，内部传 nil）；③ 实现 GET `/api/resources`、`/api/resources/{uid}`、`/api/resolve`、`/api/changes`；④ registry 为 nil 时这些端点返回 503；⑤ 测试覆盖正常/404/分页/limit 夹紧
  - 验收：`go test ./internal/api/...`
- [x] A6 cmd/server 装配（依赖：A4、A5）
  - 文件：`cmd/server/main.go`（改）
  - 步骤：创建 `registry.Service`；启动前调用 `Bootstrap` 并输出 `Stats` 日志（**不得输出文件内容或令牌**）；把 service 传入 `buildMux` 与 api/webdav 新入口
  - 验收：`go build ./...` + 启动日志含 `registry_bootstrap created=… updated=…`
- [x] A7 批次 A 验证与阶段报告（依赖：A1–A6）
  - 步骤：L1 `go build ./... && go vet ./...`；L2 `go test ./...`；L3 用临时目录 + 临时 SQLite + 环境变量令牌启动服务，执行 curl 脚本：PUT 新建 → PUT 覆盖 → MOVE → DELETE → `GET /api/changes?since=1` → `GET /api/resources?include_deleted=true`，断言 uid 全程不变、seq 连续
  - 验收：三项全过 + 输出阶段报告

### 批次 B：根映射与 REST 写

- [x] B1 `config.Roots`（依赖：无）
  - 文件：`internal/config/config.go`（改）、`internal/config/config_test.go`（改）、`config.example.yaml`（改）、`docs/configuration.md`（改）
  - 步骤：新增 `RootConfig{Tag, Path}` 与 `WebDAVConfig.Roots []RootConfig`；**新增** `func (c *Config) Validate() error`（当前 `internal/config/config.go` 无任何校验入口）并**在 `Load()` 末尾调用**：校验 tag 唯一且非空、path 非空、`roots` 至少一项；未配置 `roots` 时归一为单根 `notes`/`webdav.root`；测试改
  - 验收：`go test ./internal/config/...` 全绿；未配置 `roots` 时归一为单根 `notes`/`webdav.root`；tag 重复返回配置错误
- [x] B2 多根 bootstrap 与 `GET /api/roots`（依赖：A2、B1）
  - 文件：`internal/registry/bootstrap.go`（改）、`internal/api/resources.go`（改）、`internal/registry/bootstrap_test.go`（改）、`internal/api/resources_test.go`（改）
  - 步骤：① `Bootstrap` 遍历全部 roots（`roots[0]` 为 mirror，其余为 ondemand）；② 实现 `/api/roots`（返回 tag + `mode`：`mirror`/`ondemand`，**不回物理路径**）；③ 确认 FTS 索引只覆盖 `roots[0]`
  - 验收：`go test ./internal/registry/... ./internal/api/...` 全绿；两根本地测试目录下文件均被登记，且仅 `roots[0]` 的 `.org` 进入 FTS
- [x] B3 REST 写端点（依赖：A2、A5、B1）
  - 文件：`internal/api/files.go`（新）、`internal/api/files_test.go`（新）、`internal/api/server.go`（改）
  - 步骤：① `GET /api/files/{path...}`（读内容，支持 `Range`，可按 `?root=` 指定根，默认 `roots[0]`）；② `PUT /api/files/{path...}`（写内容：`If-Match` ETag 更新 / `If-None-Match: *` 创建，冲突 412 `etag_mismatch`）；③ `DELETE /api/files/{path...}`；④ `POST /api/resources/{uid}/move`（body `{"to":"new/path"}`）；⑤ 写操作**仅允许 `roots[0]`**（笔记根，文本内容，用 `gitver.WriteAndCommit`）；`roots[1..]` 写返回 403 `root_read_only`；⑥ 每次写后调用 `registry.Apply`（顺序：落盘 → commit → registry）
  - 验收：`go test ./internal/api/...` 全绿，新增用例 ≥8；`If-Match` 不匹配返回 412；`roots[1..]` 写返回 403
- [x] B4 状态表 uid 化与端点改造（依赖：A1、A2、A5）
  - 文件：`internal/storage/db.go`（改，追加 v7）、`internal/storage/state.go`（改）、`internal/api/server.go`（改）、`internal/api/progress_uid_test.go`（新）、`internal/storage/state_test.go`（改）
  - 步骤：① 测试先行（uid 为键的 CRUD、uid 非法 400、未登记 404）；② `db.go` 追加 v7 脚本（`schemaVersion` 5→7 中的后一半，SQL 见设计 1），`DROP` + 重建状态表；执行 `DROP` 前先 `SELECT COUNT(*)` 检查 `reading_progress` / `annotations`，任一非空则中止迁移并返回明确错误（把「无存量数据」从假设变成机械校验，对应假设 H7）；③ `state.go` 的 `Progress` / `Annotation` 结构把 `DocumentID` 改为 `UID`，SQL 全量改列；④ api 处理器改用 `r.PathValue("uid")` / `?uid=`，加 `invalid_uid` / `unknown_uid` 校验；⑤ 删除所有 `document_id` 相关 JSON 字段与参数，响应体字段改为 `uid`；⑥ 既有测试同步改
  - 验收：`go test ./internal/storage/... ./internal/api/...` 全绿，新增用例 ≥8；迁移后 `user_version=7`
- [x] B5 Emacs 客户端 uid 适配（依赖：A5，可与 B4 并行）
  - 文件：`emacs/seshat-rest.el`、`emacs/seshat-reader/seshat-reader-annotation.el`、`emacs/seshat-reader/seshat-reader-annotation-queue.el`、`emacs/seshat-reader/seshat-reader-translate.el`（均改）；`emacs/tests/seshat-reader-annotation-test.el`、`emacs/tests/seshat-reader-annotation-queue-test.el`、`emacs/tests/seshat-reader-translate-test.el`（均改）
  - **双值不变量**：`doc-id`（`tag:relpath`）只用于显示与 `seshat:` 链接文本；`uid` 只用于 API 身份。判据：凡「发给服务端」的实参一律 uid，凡「写进 buffer / 链接 / 文案」的一律 doc-id。
  - 步骤：
    ① `seshat-rest.el`：`seshat-rest-set-progress` / `seshat-rest-get-progress` / `seshat-rest-create-annotation` / `seshat-rest-list-annotations` 四个函数参数 `document-id` → `uid`；`create-annotation` 的 JSON 字段 `document_id` → `uid`；`list-annotations` 的 query 参数 `document_id=` → `uid=`；新增 `seshat-rest-resolve-uid (root path)` 封装 `GET /api/resolve?root=&path=`（返回 uid 字符串或 nil）。
    ② `seshat-reader-annotation.el`：新增 `seshat-reader-annotation--uid (file)`——按 `file-truename` 查内存 alist `seshat-reader-annotation--uid-cache`，miss 时从本地 roots 配置拆出 `(tag . relpath)` 调 `seshat-rest-resolve-uid`，失败 `user-error "文档未在服务端登记：%s"`；`--doc-id` **保持不变**（继续供显示与链接）。
    ③ **状态变量拆分**（关键）：新增 `defvar-local seshat-reader-annotation-list-uid`（存 uid，供 `--fetch` / 删除 / 刷新）；`seshat-reader-annotation-list-document-id` **继续存 doc-id**（供列表显示与 `reference.el` 生成链接）。`--render-list` 增加 uid 参数并同时 `setq-local` 两个变量；`--refresh-list` 签名改为 `(uid doc-id &optional source)`；列表的 `g` 刷新与删除路径改用 `list-uid`。
    ④ `seshat-reader-annotation-queue.el`：entry plist **增加 `:uid`**（保留 `:document-id` 作为显示用 doc-id）；同步与拉取用 `:uid`，涉及的真实函数名为 `seshat-reader-annotation-queue-entries`（:214）/ `seshat-reader-annotation-queue--sync-create`（:251）/ `seshat-reader-annotation-queue--sync-delete`（:283）/ `seshat-reader-annotation-queue-sync`（:312）；**缺 `:uid` 的旧条目跳过并 `message` 一次提示**（未部署，无需迁移）。
    ⑤ `seshat-reader-translate.el`：**必须改代码**——其「存译文为批注」路径显式调用 `(seshat-reader-annotation--doc-id file)` 并把结果传给 `seshat-rest-create-annotation`（约 :781/:785），须改用 `(seshat-reader-annotation--uid file)`；不改会把 doc-id 当 uid 发送并被服务端拒绝。
    ⑥ `seshat-reader-reference.el` **零代码改动**（只读 `seshat-reader-annotation-list-document-id`，该变量仍为 doc-id）。
    ⑦ 测试：annotation-test / queue-test / translate-test 同步调整；translate-test 的断言从「字段名 + doc-id 值」改为「字段名 + uid 值」；新增 ≥5 例（缓存命中不发请求、未登记报错、旧队列条目跳过、resolve 成功、列表刷新用 uid 而链接用 doc-id）；`seshat-reader-reference-test.el` 必须全绿（H6 的验证手段）。
  - 验收：`emacs/seshat-reader/Makefile` 的测试目标全绿；annotation / queue / translate / reference 四个 ERT 文件零失败；新增 ≥5 例
- [x] B6 `POST /api/resources/rescan`（依赖：A2、B2）
  - 步骤：调用 `Rescan` 返回 Stats；限流（同一时刻只允许一次，用 `sync.Mutex`）
  - 验收：重复调用串行执行（第二次请求等待或返回 409 `rescan_in_progress`），响应含 `Stats` 字段
- [x] B7 批次 B 验证与阶段报告（依赖：B1–B6）

### 批次 C：引用与文档

- [x] C1 refs 写入与 `GET /api/refs`（依赖：A1、A2、A4）
  - 文件：`internal/webdav/refs.go`（新）、`internal/api/refs.go`（新）、对应测试（新）
  - 步骤：`.org` 写成功后解析 `seshat:` 链接（Go `regexp`：`seshat:([^#\s)\]]+)(#[^)\]\s]+)?`），逐条 `registry.Resolve`，`ReplaceRefs`；解析失败仅日志
- [x] C2 `seshat:` 双形态的测试与文档化（依赖：C1）
  - 步骤：`registry.Resolve` 在 A2 已支持 uid / `tag:path` / 纯 path（默认根），本任务只补：① 三种输入形态的表驱动测试（含非法输入）；② 在 `docs/sync-protocol.md` 与 `docs/api.md` 写明链接解析优先级（uid → `tag:path` → 纯 path）
  - 验收：`go test ./internal/registry/...` 全绿，新增用例 ≥6
- [x] C3 文档同步（依赖：A–B 完成）
  - 文件：`docs/api.md`（重写）、`docs/sync-protocol.md`（**新建**）、`docs/architecture.md`（改）、`docs/configuration.md`（改）、`docs/errors.md`（改，加 `invalid_uid` / `unknown_uid`）、`docs/adr/0003`、`0004`（**修订**：迁移描述改 v6/v7 拆分、删除 legacy 映射表与「单条 v6」表述、Emacs 段改双值四模块）、`CHANGELOG.md`（改）、`openspec/decisions.md`（改）、`openspec/tech-debt.md`（改）、`openspec/active/roadmap.md`（改）
  - 附带动作（本计划只记录该动作，roadmap 实际修正由后续批次执行）：修正 `openspec/active/roadmap.md` M7.1 验收要点「存量 progress/annotations 成功映射 uid」→「v7 重建状态表、无存量迁移」
- [x] C4 归档与汇总（依赖：C3）
  - 步骤：L1/L2/L3 全跑；本计划移入 `openspec/completed/`；`codegraph index`；汇总报告（含「## 根本问题与假设」H1–H7 的逐条复盘）

## 文档清单

| 文档 | 动作 | 触发原因 |
|---|---|---|
| `docs/api.md` | 重写 | 10 个新端点 + uid 语义 + 破坏性变更说明（不再接受 document_id） |
| `docs/sync-protocol.md` | 新建 | roadmap M7.5 要求；该文件当前不存在 |
| `docs/architecture.md` | 更新「同步协议」章节 | 身份模型与增量同步 |
| `docs/configuration.md` | 更新 | `webdav.roots` 多根配置 |
| `docs/errors.md` | 更新 | 新增 `invalid_uid`、`unknown_uid` 等错误码 |
| `docs/adr/0003-uid-identity-model.md` | **修订**（ADR 已建；批次 C 按实现更新迁移描述 v6/v7、Emacs 双值段） | 重大架构决策 |
| `docs/adr/0004-incremental-change-log.md` | **修订**（同上：表结构归属改 v6/v7、删 legacy 表述） | 重大架构决策 |
| `CHANGELOG.md` | 更新「新增」「变更」「破坏性」 | 对外契约变更 |
| `docs/android.md` | 追加一节 | 说明 Android 端文档标识将由 SHA-256 改为服务端 uid（M9.2 后续落地，本计划不改代码） |
| `openspec/decisions.md` | 追加 | 决策日志 |
| `openspec/tech-debt.md` | 更新 | EPUB location、`#/%` 文档名、tag 反向解析、`:complete` 依赖等条目 |
| `openspec/active/roadmap.md` | 更新 M7 节 | 记录落地 |
| `docs/llm.md`、`docs/security.md`、`docs/deploy.md` | 不动 | 无相关变更 |

## 验证标准

| 级别 | 命令 | 通过判据 |
|---|---|---|
| L1 | `cd /home/thomas/WorkSpace/notes && go build ./... && go vet ./...` | exit 0 |
| L2 | `cd /home/thomas/WorkSpace/notes && go test ./...` | 全绿，新增用例 ≥40 |
| L3 | 临时 DB + 临时根启动服务，curl 脚本：PUT 新建→PUT 覆盖→MOVE→DELETE→增量拉取→`/api/resolve`→`?uid=` 读进度 | uid 全程不变；`changes` seq 连续无空洞；`?uid=` 正常；`?document_id=` 被拒绝（不带 `uid` 时返回 400 `invalid_uid`） |

说明：项目无 `make test-in-docker` 或等价容器入口，L1–L3 走宿主 Go 工具链。
各任务「新增用例 ≥N」为**参考下限**，最终验收以该任务列出的具体行为断言为准（禁止为凑数写空测试）。

Emacs 侧另跑 `emacs/seshat-reader` 的 ERT（`make test` 或等价目标），新增 ≥5 例、全绿。

## 注意事项

- **TDD 强制**：A1/A2/A3/A4/A5/B1/B3/B4/B5/C1 均先写测试并见红。
- **不改既有函数签名**：`gitver.Commit` / `WriteAndCommit`、`webdav.VersionedHandler` / `VersionedHandlerWithIndex` / `NewPolicyVersionedHandler`、`api.NewHandler*` 全部保留，只新增带 `WithRegistry` 的入口。
- **迁移只追加**：`migrations` 数组只追加 v6、v7，禁止改 v1–v5。
- **迁移拆两次**：v6 只建身份三表（A1）；v7 重建状态表（B4）。两条都只追加、不改 v1–v5，且各自在所属批次内保持「交付即自洽」（批次 A 结束时 `state.go` 无需改动）。
- **Go 1.22 路由限制**：`{path...}` 通配段之后不得再有字面量段（会 panic）。移动端点用 `POST /api/resources/{uid}/move`；新增其他带子路径的动作端点时先自查此约束。
- **schemaVersion 与 len(migrations) 一致**（既有测试 `TestMigrationsLengthMatchesVersion` 守卫）。
- **DB 单连接**：`Open` 已 `SetMaxOpenConns(1)`，registry 事务不可嵌套长耗时操作（bootstrap 逐条提交会慢，改为每 N 条一批事务或单事务内批量 —— 实现时按书库规模选择，但**不得**在事务内做文件哈希/IO）。
- **不登记**：`.git` 目录、以 `.` 开头的目录、非普通文件（目录/符号链接）。
- **public 出口**：root 标签同为 `roots[0].tag`，path 需 `path.Join(offset, rel)`；否则第三方写入的文件无 uid。
- **FTS 只索引 `roots[0]`**（现状 `orgSuffix` + offset 逻辑不变）。
- **零新增依赖**：uid 用标准库；不得引入 uuid/ulid 库。
- **错误码**：新错误码加入 `internal/logging` 常量与 `docs/errors.md`；HTTP 映射 400 `invalid_uid`、404 `unknown_uid`、412 `etag_mismatch`、403 `root_read_only`。
- **日志红线**：不得输出令牌、密钥、文件内容；只输出计数、uid、路径。
- **不得读取** `data/secrets.env`、`android/keystore.properties`、`android/release.keystore`。
- **不改 `android/`**（M9.2 已完成归档，Android 数据源接入留给后续里程碑）；Emacs 只改任务 B5 列出的四个模块 + 对应测试。
- **破坏性变更（已获用户确认）**：状态 API 不再接受 `document_id`；v7 迁移会 `DROP` 旧状态表。提交信息与 CHANGELOG 必须显式标注 breaking，禁止含糊表述。
- **Emacs 双值不变量与改动边界**：`doc-id` 只用于显示与 `seshat:` 链接文本，uid 只用于 API 身份。改动限于 B5 列出的 4 个模块 + 3 个测试文件；`seshat-reader-reference.el` **零代码改动**（只读 `list-document-id`），但 `seshat-reader-reference-test.el` 必须跑通。判据复核点：所有 `seshat-rest-*` 实参、所有队列 entry 的同步字段必须是 uid；所有 `seshat:` 链接文本、列表显示必须仍是 doc-id。不得顺手重构 ETAF / 面板结构。
