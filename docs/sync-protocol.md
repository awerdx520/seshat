# 同步协议（面向客户端实现者）

本文件描述如何在客户端实现「与服务端保持一致」的同步逻辑：身份从哪里来、增量怎么拉、
写冲突怎么处理、引用与阅读状态怎么挂载。它描述的是**契约**（哪些行为可以依赖）与
**边界**（哪些行为不要依赖），端点细节见 [REST API 规范](api.md)。

设计依据：[ADR-003 uid 身份模型](adr/0003-uid-identity-model.md)、
[ADR-004 增量变更日志](adr/0004-incremental-change-log.md)、
[ADR-001 git 版本化与冲突消解](adr/0001-git-versioning-conflict-resolution.md)。

## 1. 概述与不变量

客户端需要在这个协议上建立的全部预期，可以压缩成五条不变量：

1. **服务端权威**。文件身份（uid）、根映射、变更序列、引用图、阅读进度与批注的合并
   规则，全部由服务端裁决。客户端不充当第二权威，也不假设「本地视图正确」。
2. **uid 是身份，路径是属性**。改名/移动只改路径，uid 不变；因此进度、批注、引用永远
   挂在 uid 上，不需要在改名时迁移。
3. **客户端不生成 uid**。uid 只能从服务端获得（`/api/resolve`、`/api/resources`、
   `/api/changes`、写入响应）。客户端生成的任何 id 都只能作本地键，不得用于 API。
4. **单一全局游标**。全部根（笔记根、书库根）共用一个单调递增的变更序列，客户端只需
   持久化一个整数 `cursor`。
5. **登记是派生状态**。`resources` + `changes` 可由文件系统重建（`rescan`）。这使
   「钩子漏记」是可修复问题而非数据损坏——但也意味着**不要**把变更流当成审计日志。

典型的同步拓扑：

- 客户端与「笔记根」之间可以走 WebDAV（全量镜像 + 文件管理器语义），也可以只走 REST；
- 客户端与「书库根」（电子书等大文件）之间只走 REST，按需取片段（`Range`）；
- 状态（进度、批注）始终走 REST。

## 2. 身份模型

### 2.1 uid 形态与校验

| 项 | 值 |
|---|---|
| 长度 | 26 字符 |
| 字母表 | Crockford Base32：`0123456789ABCDEFGHJKMNPQRSTVWXYZ`（排除 `I`/`L`/`O`/`U`） |
| 校验正则 | `^[0-9A-HJKMNP-TV-Z]{26}$` |
| 生成 | 服务端 `crypto/rand` 取 16 字节（128 位）→ 无填充 Base32 |
| 大小写 | 仅大写；小写形态视为非法 |

客户端应在本地按同一正则做前置校验，把明显拼错的参数挡在请求之前：

- 形态非法 → 服务端 `400 invalid_uid`（**改参数**）；
- 形态合法但未登记/已墓碑 → 服务端 `404 unknown_uid`（**重建本地缓存或走变更流补齐**）。

两者的区分是行动指引，不是文案差异。

### 2.2 `resources` 登记行

| 字段 | 含义 | 客户端用途 |
|---|---|---|
| `uid` | 权威身份（主键） | 本地索引主键；状态/引用/事件的关联键 |
| `root` | 根 tag（如 `notes`、`ebooks`） | 决定用哪条读写通道 |
| `path` | 根内逻辑相对路径（无前导 `/`） | 本地文件布局；仅作定位提示 |
| `kind` | 类型，当前恒为 `file` | 预留 |
| `blob` | 内容 blob hash（mirror 根为 git blob sha1；ondemand 为空串） | 判断内容是否需要重新下载 |
| `rev` | 最后一次登记时的提交 hash（**尽力而为**，可能为空） | 排查/审计；不要作为同步条件 |
| `size` | 字节数 | 下载预分配、进度估算 |
| `mtime` | 文件 mtime（Unix 秒） | 粗粒度「是否有变」判断 |
| `created_at` | 首次登记时间（RFC 3339 UTC） | 展示 |
| `updated_at` | 最后更新时间 | 展示 |
| `deleted_at` | 空串 = 存活；非空 = 墓碑时间 | 区分「删除」与「未知」 |

### 2.3 `(root, path)` 唯一与墓碑

- 同一根内同一路径**最多对应一个 uid**（`UNIQUE(root, path)`）；
- **删除不物理删行**：写入 `deleted_at`，`path` 保留删除前值，同时追加 `delete` 事件；
- 墓碑仍占用 `(root, path)`：文件在同一路径重建时**复用原 uid**（墓碑复活），因此
  「删了又建」不会产生第二个 uid，客户端缓存的 uid 仍然有效；
- 墓碑对绝大多数端点等同「不存在」：`GET /api/resources/{uid}` → `404 unknown_uid`；
  只有 `GET /api/resources?include_deleted=true` 与 `GET /api/changes` 能看到它。

### 2.4 改名不改 uid

`rename` 只改 `resources.path`，uid 与 `created_at` 不变。因此：

- 本地不必为改名做「进度/批注迁移」；
- 客户端收到 `rename` 事件时，应按 `old_path` 在**本地**做文件重命名，而不是
  「删掉旧文件 + 下载新文件」——后者会浪费带宽，也会短暂丢失本地未上传状态。

## 3. 根映射

```
GET /api/roots
→ {"roots":[{"tag":"notes","mode":"mirror","default":true},
            {"tag":"ebooks","mode":"ondemand","default":false}]}
```

| mode | 含义 | 读写能力 |
|---|---|---|
| `mirror` | 笔记根：WebDAV 全量镜像、git 版本化、FTS 索引 | WebDAV 与 REST 均可写；有内容哈希 |
| `ondemand` | 书库根：不进 git、不在 WebDAV 暴露、按需经 REST 读取 | **只读**（写 → `403 root_read_only`）；`blob` 恒为空 |

客户端要点：

1. **根映射以服务端为权威**，不要从本地配置推断根名或顺序；启动时拉一次 `/api/roots`
   即可（根配置变更需重启服务端，运行期不会漂移）。
2. `default: true` 的根是默认根：省略 `?root=` 时使用它，`doc_id` 的纯路径形态也以它
   为默认根。
3. 响应**不含物理路径**（服务端部署细节），不要试图获取或缓存它。
4. 按 `mode` 决定通道：`ondemand` 根不要尝试 WebDAV 或写入；写请求会得到
   `403 root_read_only`，正确处理是回退为只读展示，而不是重试。

## 4. 变更流与游标

### 4.1 游标不变量

- `changes.seq`：SQLite `AUTOINCREMENT`，**全局单调递增、跨全部根共用一个序列、不复用**；
- `changed_at` 是事件时间（RFC 3339 UTC），**不是**游标——不要用它排序或去重；
- 客户端只持久化一个整数 `cursor`（最后成功消费的 `seq`）；
- 无事件时 `next_cursor` 回传请求的 `since`：游标不倒退，重试安全。

### 4.2 拉取循环

```
cursor = store.load_cursor()            # 首次同步：0
loop:
    resp = GET /api/changes?since=cursor&limit=500
    for ev in resp.changes:
        apply_event(ev)                 # 见 §4.3
    cursor = resp.next_cursor
    store.save_cursor(cursor)           # 先应用、后推进；崩溃后可安全重放
    if resp.has_more:
        continue                        # 立即再拉一轮，不要 sleep
    sleep(poll_interval)                # 空闲轮询
```

要点：

1. **先应用事件、再保存游标**。事件重放是安全的（按 uid upsert 语义），丢游标则要重拉。
2. `has_more=true` 时必须立刻再拉，不要插入 sleep——否则同步速度被轮询周期卡住。
3. 每批最大 2000 条（`limit` 夹紧到 `[1, 2000]`，默认 500）。
4. `limit` 传非整数会 `400 invalid_argument`；传越界值会被夹紧而不是报错。

### 4.3 四类事件的处理

| `op` | 语义 | 客户端动作 |
|---|---|---|
| `create` | 新资源 | 本地按 `uid` upsert 记录；需要内容时下载（`GET /api/files/{path}?root=` 或 WebDAV） |
| `update` | 同路径内容更新 | 比较本地已知 `blob` 与事件 `blob`；不同则重新下载。`blob` 为空（ondemand 根）时改用 `size`/`mtime` 或直接按需重取 |
| `rename` | 改名/移动，uid 不变 | 本地把 `old_path` 重命名为 `path`；更新记录里的路径；**不要**改 uid，不要动进度/批注 |
| `delete` | 删除 | 本地标记墓碑或删除文件内容；**保留 uid 的本地历史状态**（进度、批注、缓存），因为同路径重建会复活同一 uid |

补充规则：

- `old_path` 仅 `rename` 事件有值；其余事件为空串。
- 事件顺序即 `seq` 顺序，但**不保证**同一 uid 的事件在业务上成对出现（例如批量目录
  删除会为每个资源各发一条 `delete`）。
- 事件中的 `blob`/`rev` 是**尽力而为**：WebDAV `MOVE` 的事件不带内容元数据（`blob` 空
  串、`size`/`mtime` 为零值），未装配仓库时 `rev` 为空串。不要用「`rev` 为空」判定失败。

### 4.4 bootstrap 产生的 create 洪峰

服务端启动时会对全部根做一次 bootstrap（遍历文件系统登记），结果是一批 `create`
事件（数量级等于首次部署时的文件数）。客户端必须容忍：

- 这些 `create` 可能指向本地**已存在**的文件 → 按 upsert 处理，不要报「重复创建」；
- 首次接入的客户端应直接以 `since=0` 循环消费（事件量等于库内文件数），循环结束时把
  `next_cursor` 存为起点游标；若选择先用 `GET /api/resources` 建立基线，则仍需消费一遍
  变更流才能得到「最新游标」（见 §10 第 9 条）。

### 4.5 事件缺失的兜底

写钩子失败（进程崩溃、外部工具直接改盘、钩子未挂）会造成**事件永久缺失**——服务端
不会自动补发。兜底手段：

1. 调 `POST /api/resources/rescan`（维护动作，同一时刻只允许一次，冲突时 `409`
   `rescan_in_progress`）；
2. 用 `GET /api/resources`（可带 `include_deleted=true`）拉全量清单与本地比对；
3. 在本地补齐缺失变化后，持续消费 `GET /api/changes?since=<cursor>` 直到 `has_more=false`，
   使本地视图与服务端对齐（游标只前进、不倒退）。

判定「何时需要兜底」的实用信号：本地记录与服务端清单的 `uid` 集合出现对称差，或某条
下载请求返回 `404 unknown_uid`（本地认为存在但服务端没有）。

## 5. 写路径与事件产生

### 5.1 统一顺序：落盘 → commit → registry

所有写路径（WebDAV 内部出口 `/dav/`、对外出口 `/public/`、REST 文件端点）共用同一顺序：

1. 写入工作区文件（与 commit 在同一持锁临界区内完成）；
2. git commit（仅 `mirror` 根）；
3. 写 `resources` + `changes`（同一事务内 upsert 登记 + append 事件）。

推论（客户端必须知道的）：

- **`.git` 与点路径不可写入**：路径任一段为 `.git`（大小写不敏感）或以 `.` 开头时，
  REST 文件端点（`PUT`/`DELETE`）与 WebDAV 两个出口（`/dav/`、`/public/`，含 `PUT`、
  `MKCOL`、`MOVE`、`COPY`、`PROPPATCH`）一律拒绝——REST 返回 `400 invalid_argument`，
  WebDAV 返回 `403 Forbidden`。客户端不必（也不能）用「写 `.git` 内文件」做任何操作；
- **符号链接不参与同步**：登记与重扫只收普通文件，符号链接不登记、不产生事件；REST
  读端点对软链返回 `404`、写端点返回 `400`；WebDAV 两个出口（`/dav/`、`/public/`）由
  `symlinkGuardFS` 拒绝（`403`，父链或目标自身含软链即拒，PROPFIND 中该项被静默跳过）
  ——见 `docs/api.md` §8 与 `docs/security.md` §8.7；
- **登记失败时文件已落盘**：服务端返回 500，但内容已在磁盘上；修复靠 bootstrap/rescan。
- **事件带的是 commit 之后的 `rev`**（WebDAV 钩子挂在 commit 外层才有这个能力）；
- 反过来「先登记后落盘」会产生指向不存在文件的登记行，服务端刻意不这么做。

### 5.2 各写方法对应的事件

| 写操作 | 事件 | uid |
|---|---|---|
| WebDAV `PUT` / REST `PUT /api/files/...` | 路径已存活 → `update`；未登记 → `create`；**只有墓碑** → 复用墓碑 uid 并复活（`update`，服务端归一为 `create`） | 存活时不变；新建时服务端生成 |
| WebDAV `COPY` | 目标侧一律 `create` | **新 uid**（复制的是内容而非身份）；目录 COPY 对子树内每个文件各生成一个新 uid |
| WebDAV `MOVE` / REST `POST /api/resources/{uid}/move` | `rename`（`old_path` 记原路径） | **不变** |
| WebDAV `DELETE` / REST `DELETE /api/files/...` | `delete`（每个受影响存活资源一条） | 不变（写墓碑） |
| WebDAV `MKCOL` / `PROPPATCH` | 不登记（目录不是资源） | — |

### 5.3 目录级批量语义

目录 `MOVE` / `DELETE` 按「路径段边界」匹配存活资源（`path` 恰等于目标，或 `path` 的前缀
恰为「目标 + `/`」），对子树内**每个存活资源各写一条事件**：

- 目录 `MOVE`：每个资源一条 `rename`，`path = 目标路径 + 原路径相对源路径的后缀`，uid 不变；
- 目录 `DELETE`：每个资源一条 `delete`，各自写墓碑。

注意批量操作**不是单事务**：逐条应用，单条失败只记日志并继续。因此客户端可能看到
「部分成功」的目录操作，必须按事件逐条处理，不要假设原子性。

## 6. 冲突与并发

### 6.1 ETag = git blob hash

- `GET /api/files/{path...}` 的 `ETag` 是内容 blob hash（`sha1("blob <size>\0<content>")`，
  与 git 对象格式一致），带引号；
- `resources.blob`、写入响应里的 `blob`/`etag` 用的是同一算法，因此在 `mirror` 根上三者恒等；
- ETag 是**内容**标识，不是身份：改一个字符 ETag 就变。它适合做乐观锁，不能当 id 用。

### 6.2 条件写（乐观锁）

| 场景 | 请求 | 冲突结果 |
|---|---|---|
| 覆盖写，要求「我看到的版本」 | `If-Match: "<blob>"` | 不匹配或资源不存在 → `412 etag_mismatch`，内容不变 |
| 仅创建，不得覆盖 | `If-None-Match: *` | 目标已存在 → `412 etag_mismatch` |
| 条件读，避免重复下载 | `GET` + `If-None-Match: "<blob>"` | 内容未变 → `304 Not Modified` |

两者同时出现时**两者都校验**（不是二选一）：`If-Match` 匹配必然意味着资源存在，故与
`If-None-Match: *` 组合时恒为 `412`——这是「两个前提不可同时成立」的正确表达，客户端不要
这样发。服务端只发强 ETag；`W/` 前缀会被忽略强弱差异。

> **WebDAV 通道不提供条件写**：`/dav` 与 `/public` 出口的 `PUT` 不解析 `If-Match` /
> `If-None-Match`（`x/net/webdav` v0.61.0 的 `handlePut` 未实现），条件头被静默忽略、
> 退化为无条件覆盖；因此**冲突检测必须走 REST**（`PUT /api/files`）**或用 `merge-base`**，
> 不能依赖 WebDAV 客户端的条件头。见 `docs/security.md` §8.8。

**条件比较与写入在同一临界区内完成（原子）**：服务端在同一把锁内做「读当前 ETag → 比较 →
写文件 → commit」，不存在「校验通过 → 内容被并发改掉 → 覆盖掉别人的写入」的时间窗。
因此并发两个携带**相同** ETag 的写只有一个成功（`200`），另一个必定拿到
`412 etag_mismatch`——`If-Match` 可以直接当乐观锁用，无需客户端额外加锁或串行化。

两条补充语义（实现已固化，供客户端建模）：

- `If-None-Match: *` 的「已存在」=「登记表有存活行 **或** 磁盘上文件存在」，任一为真即
  `412`；
- **空 ETag 永不匹配**：`If-Match: ""` 不会退化为「无条件写」，而是直接 `412`。不要用
  空 ETag 表达「我不管当前内容」——那应当不发条件头。

### 6.3 冲突后的重试建议

1. `412` → 重新 `GET` 当前内容与 ETag（或用 `/api/changes` 拉到最新 `blob`）；
2. 本地与远端做合并（文本笔记的三方合并由 git 版本化承担，见
   [ADR-001](adr/0001-git-versioning-conflict-resolution.md)；REST 客户端可用
   `/api/versions`、`/api/merge-base`、`/api/revert` 辅助）；
3. 用新的 ETag 重发 `PUT`；
4. **不要**在 `412` 后无条件重试同一请求（会无限冲突），也不要「先 DELETE 再 PUT」
   绕过条件写（会产生墓碑与额外事件）。

### 6.4 并发写与写入顺序

- 服务端的写与 commit 在同一持锁临界区内，客户端不必担心「读到半写状态」；
- 客户端并发上传同一文件时，只有条件写能保护你；后写覆盖语义对无条件写成立。

## 7. 阅读进度与批注

### 7.1 键是 uid

| 端点 | 键 |
|---|---|
| `GET\|PUT /api/progress/{uid}` | 路径参数 uid |
| `POST /api/annotations` | 请求体 `uid` |
| `GET /api/annotations?uid=` | 查询参数 uid |

旧 `document_id` 不再接受（M7 破坏性变更，见 [api.md §14](api.md#14-破坏性变更说明m7)）。
客户端若本地还存着 `tag:path` 或内容哈希形态的旧 id，必须先调 `GET /api/resolve`
换成 uid。

### 7.2 时间戳乐观冲突（409）

进度与批注都采用「时间戳乐观锁」：

- 写入时**带** `updated_at`（客户端视角的当前版本时间）：
  - 服务端记录的 `updated_at` **晚于**该值 → `409 conflict`，不覆盖；
  - 相等或更早 → 覆盖，值即新的 `updated_at`；
- 写入时**不带** `updated_at` → 服务端填当前 UTC，视为无条件覆盖（后写赢）。

客户端建议：

1. 每次拉取进度/批注时记住 `updated_at`；
2. 上传时带上它；
3. 收到 `409` 时重新拉取、合并本地变更（例如保留本地较新的 `position` 提示用户），
   再用新时间戳重发——不要用「当前时间」硬覆盖（会掩盖另一端的最新状态）。

### 7.3 location 约定

`location` 对服务端是不透明字符串，跨端语义由客户端约定：

- PDF 矩形：`page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（1-based 页码，PDF point 空间，
  两位小数，不含缩放；不支持旋转页面）；
- PDF 手写：`page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`（已定义，客户端尚未上传）；
- EPUB：**尚未定义**，见 `openspec/tech-debt.md`。

细节见 [api.md §4.5](api.md#45-location-约定pdf)。

## 8. 引用图

### 8.1 `seshat:` 链接的两种形态

`.org` 文件中的链接写法：

```
seshat:01K8Q3M7D2X9V6T1B8N5C0RDEX#chapter-3      ← uid 形态
seshat:notes:journal/2026-10-18.org#chapter-3   ← tag:path 形态
seshat:journal/2026-10-18.org#chapter-1         ← 纯 path（默认根）
```

- `#` 之后是目标内位置（`target_location`），可为空；
- target 段取到 `#`、空白、`)`、`]` 为止，因此 org 链接与裸文本写法都能识别。

### 8.2 解析优先级

`uid` → `tag:path` → 纯 path（默认根）：

1. 形态是合法 uid → 按 uid 查（墓碑视为不存在）；
2. 含 `:` → 首个冒号前为根 tag，其后为路径；
3. 否则按默认根（`roots[0]`）解释。

同一套规则同时用于 `GET /api/resolve?doc_id=` 与写入时的引用刷新，故两种写法在任何
时候都指向同一 uid。

### 8.3 引用边的生命周期

| 触发 | 行为 |
|---|---|
| 写入 `.org`（WebDAV 或 REST，成功登记后） | 重解析全文，**整份替换**该源的出边（单事务先删后插），幂等 |
| 写入非 `.org`（附件等） | 不触发刷新（引用图只随 `.org` 写入更新） |
| `.org` 改名为其它扩展名 | `rename` **不触发**刷新，旧出边会残留；该路径下次被 `PUT` 写入时，刷新逻辑因扩展名非 `.org` 而清空其全部出边 |
| 删除资源 | 清空该 uid 的出边（它已不再是任何东西的源） |
| 目标解析不到（未登记/已墓碑/非法 key） | **跳过该条**，不产生悬空边、不影响其余引用 |
| 同一目标的不同位置 | 视为不同引用（`target_location` 不同即不同边） |
| 不同写法指向同一 uid 的同一位置 | 落库前合并（去重键为 `uid + location`） |

查询：

```
GET /api/refs?uid=<uid>&direction=out   # 我引用了谁
GET /api/refs?uid=<uid>&direction=in    # 谁引用了我
```

`source_location` 目前恒为空串（源侧位置尚未采集），客户端不要依赖它。

## 9. 客户端实现清单

按顺序实现即可得到一个可用的同步客户端。每步标注用到的端点。

| 步骤 | 动作 | 端点 |
|---|---|---|
| 1 | 拉根映射，决定每个根的通道（mirror/ondemand）与默认根 | `GET /api/roots` |
| 2 | 首次全量：以 `since=0` 循环消费变更流（`has_more` 为真就继续），边消费边应用；文件数很大时也可先用资源清单建索引，再用变更流补齐 | `GET /api/changes?since=0&limit=2000`（循环）/ `GET /api/resources?limit=2000`（配合 `prefix`/`since`） |
| 3 | 记录起始游标：步骤 2 循环结束时的 `next_cursor` 就是当前最新 `seq`（服务端**没有**「查最新游标」的独立端点，必须靠消费或清单推断） | 无（沿用步骤 2 的 `next_cursor`） |
| 4 | 增量循环：按 §4.2 拉事件、按 §4.3 应用、推进并保存游标 | `GET /api/changes?since=<cursor>&limit=500` |
| 5 | 按需下载：mirror 根可走 WebDAV 或 REST；书库根只走 REST（分片用 `Range`）；条件读避免重复下载 | `GET /api/files/{path...}?root=`（+ `If-None-Match` / `Range`） |
| 6 | 路径 ↔ uid 互转（本地保存的是路径、API 需要 uid 时） | `GET /api/resolve?root=&path=` 或 `?doc_id=` |
| 7 | 上传本地变更：条件写避免覆盖他人；新建用 `If-None-Match: *` | `PUT /api/files/{path...}` / `POST /api/resources/{uid}/move` / `DELETE /api/files/{path...}` |
| 8 | 上传阅读状态：带 `updated_at` 做乐观锁，`409` 时重拉合并 | `GET\|PUT /api/progress/{uid}` |
| 9 | 上传/拉取批注 | `GET /api/annotations?uid=`、`POST /api/annotations`、`PUT\|DELETE /api/annotations/{id}` |
| 10 | 引用解析与展示：拉出边/入边，按 uid 取资源详情渲染 | `GET /api/refs?uid=&direction=` + `GET /api/resources/{uid}` |
| 11 | 异常兜底：事件缺失或本地/服务端不一致时重扫并对齐游标 | `POST /api/resources/rescan` + 步骤 2/3 |

实现要点：

- **游标只有一个**：跨根共享，不要为每个根维护独立游标；
- **uid 不落成可变键**：本地文件系统可以用路径布局，但索引主键必须是 uid；
- **状态上传失败不阻塞内容同步**：进度/批注与文件内容走两条通道，可分别重试；
- **`403 root_read_only` 不重试**：它是架构约束（书库只读），不是暂时故障；
- **`503 unavailable` 可重试**：服务端能力未就绪（未装配 registry/indexer），属部署问题。

### 9.1 Android 客户端实现要点（M9.2 B 批）

- **按需下载用整份 `GET`，未用 `Range`**：`GET /api/files/{path...}?root=` 一次拿全文，先写 `<name>.part`，`close()` 后原子 `renameTo`、异常路径删 `.part`。服务端支持的单区间 `Range`（206/416）与 `If-None-Match`（304）客户端**均未接入**，因此无断点续传，重试即从头开始。
- **上传前本地校验 32 MiB**：服务端 `PUT /api/files` 单次请求体上限 32 MiB，超限返回 `400 invalid_argument`。客户端把上限写成常量（`RestClient.MAX_UPLOAD_BYTES`）并在**发请求前**拦截提示，避免「大文件神秘失败」；新建用 `If-None-Match: *`。
- **`since` 是秒级 mtime，不是游标**：回填 `size`/`mtime` 用 `GET /api/resources?root=&since=&limit=`，语义 `mtime >= since` 且响应体**无 `next_cursor`**。分页只能取本页 `max(mtime)` 前进；若该页没有任何时间前进（同秒条目已在上一页返回完）必须 `since += 1`，否则原地死循环。故回填**不保证单次全量**，只保证「下次再跑会补齐」（尽力而为 + 幂等）。
- **`move` 只限 mirror 根**：`POST /api/resources/{uid}/move` 对 `ondemand` 根返回 `403 root_read_only`，客户端不应为它准备重命名逻辑——`ondemand` 根也不会有 `rename` 事件。mirror 根内的 rename 事件可用来跟随本地文件名，但**仅当目标不存在时**才能移动（同名不同目录会冲突，跳过不覆盖）。

## 10. 已知限制

以下均从当前实现的事实提取（不是规划），客户端需据此设计降级路径。

1. **MOVE 到被墓碑占用的路径返回 409**。墓碑仍占用 `UNIQUE(root, path)`；`move` 的
   登记步骤会因唯一约束返回 `409 conflict`。此时**物理移动已完成**（顺序为「落盘 →
   commit → registry」），需用 `POST /api/resources/rescan` 对齐登记。客户端在收到
   `409` 后应重新拉取清单/变更流，而不是立即重试同一移动。
2. **事件 `rev`/`blob` 是尽力而为**。`rename` 事件不携带新的内容元数据（移动不改内容）：
   其 `blob`/`size`/`mtime` 沿用登记行既有值（登记时对空值/零值不覆盖），服务端也不对
   移动后的路径重新 stat。未装配仓库、空仓库或读 HEAD 失败时 `rev` 为空串；`ondemand`
   根的 `blob` 恒为空串。不要以「字段为空」判定事件无效。
3. **书库根不可写**。`ondemand` 根的 `PUT`/`DELETE`/`move` 一律 `403 root_read_only`；
   其 `blob` 恒为空串（不在 git 仓库内，不计算内容哈希），因此 §4.3 的「按 `blob`
   判断是否需要重新下载」在书库根上不可用，需改用 `size`/`mtime` 或按需重取。
4. **目录级写操作不是原子批量**。目录 `MOVE`/`DELETE` 逐条应用事件，单条失败只记日志；
   客户端可能观察到「部分成功」，必须按事件逐条处理并在必要时走 rescan 兜底。
5. **重扫不可并发**。`POST /api/resources/rescan` 同一时刻只允许一次，第二次立即
   `409 rescan_in_progress`（不排队）。客户端定时任务应先检查/退避，不要并发触发。
6. **`GET /api/resources` 无 offset 分页**。只能用 `has_more` 判断是否还有更多，继续
   拉取需收窄 `prefix`/提高 `since`；需要「从头到尾」的可靠遍历时优先用变更流。
7. **EPUB 批注位置尚无跨端约定**（PDF 已有），见 `openspec/tech-debt.md`。
8. **没有「查询最新游标」的端点**。服务端不暴露 `changes` 的最大 `seq`；客户端要得到
   当前最新游标，只能从 `since=0` 消费到 `has_more=false`（首次接入），或持续消费自己的
   游标直至清空。`GET /api/changes` 不带 `since` 等同于 `since=0`（返回最早的批次），
   不要误当作「最新」。
9. **单文档引用最多保留 2000 条**。写入时超出部分按首次出现顺序截断（写仍成功，服务端
   记日志），`GET /api/refs` 因此最多返回 2000 条；结果恰为 2000 条时不要假定「这就是
   全部」。

以下限制已在 **M7 修复轮（2026-10-18）**解除，不再需要按旧口径做降级（保留记录以免按
历史文档做多余兜底）：

- ~~资源清单的 `prefix` 是未转义的 LIKE，路径含 `%`/`_` 会多命中~~ → 已改为**大小写敏感
  的精确段边界匹配**（`path` 等于 `prefix`，或其前缀恰为 `prefix + '/'`）；`prefix` 结果
  不再是超集，客户端无需二次按 `path` 精确过滤；
- ~~`If-Match` 的「读 → 比较 → 写」非原子~~ → 条件比较与写入已收进同一临界区（见 §6.2）；
- ~~`GET /api/files` 把文件整体读入内存~~ → 已改为流式传输，大文件按 Range 增量取用仍有效；
- ~~`.git`/点路径可经端点访问~~ → REST 与 WebDAV 两侧一致拒绝（见 §5.1）。
