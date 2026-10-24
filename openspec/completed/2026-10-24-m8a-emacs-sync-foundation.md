# M8-A：Emacs 同步地基（传输统一 · REST 扩展 · 状态库）

## 当前状态

- 阶段：Phase 4（Review & Document）· **代码与测试完成（2026-10-24）**
- 已确认：M8 整体方案 ✅（用户 2026-10-24）、本计划 3 个技术决策 ✅（用户 2026-10-24）、计划 ✅（用户 2026-10-24）
- 执行结果：T1 / T2(T2a+T2b) / T3 / T4 全部完成；新增 5 个文件（2 产品 + 3 测试）+ 修改 1 个（`seshat-rest.el`）；全仓 ERT 399 → **517**，0 unexpected / 0 skipped；三个产品文件与新测试文件 L1 **0 warning 0 error**（分文件：annotation-queue 27 / annotation 48 / annotation-v8 14 / etaf 18 / outline 24 / page-join 26 / reference 50 / resize 80 / select-flash 8 / sidebar 57 / translate 47 / rest 55 / state 30 / transport 33）
- 下一步：计划已归档至 `openspec/completed/`；计划 B（增量引擎：pull/push/move 检测）与计划 C（多根 / `seshat:` link / 透明性）另行 Phase 1

## 目标

只做三件**纯新增、零用户可见行为变更**的地基工作：

1. **传输统一**：新增 `seshat-transport.el`，把「HTTP 请求」收敛为单一契约 `(:status N :headers ALIST :body STRING)`，后端可换（`url.el` / `curl`）。
2. **REST 封装补齐**：扩展 `seshat-rest.el`，补齐 M8 需要的 9 个服务端端点封装。
3. **状态库**：新增 `seshat-state.el`，用单一 `.eld` 承载 uid↔path、per-uid base blob、全局 cursor、dirty 集合与墓碑。

**明确不做**（属计划 B / C）：不改 `seshat-sync-pull-all` / `seshat-sync-push-all` / `seshat-sync-now` 的现有行为；不删 WebDAV 代码；不动 `seshat-conflict.el`；不接入 `/api/changes` 增量循环；不做多根、不做 `seshat:` link follow。

## 根本问题

M8 的根因是现有 Emacs 同步器的三条基础假设与服务端 M7 模型不兼容（详见 M8 整体方案）。本计划只地基处理其中的「传输契约分裂」与「状态层缺失」两条：

1. **传输契约分裂**：`seshat-sync--request`（`emacs/seshat-sync.el:99`）返回 `(exit-code . output)`，`seshat-rest--request`（`emacs/seshat-rest.el:70`）返回 `(status . body)`，两者语义不可互换；且 `/dav` URL 拼接散落三处（`seshat-sync.el:93`、`seshat-sync-cmd.el:85`、`seshat-conflict.el:139`），改一处漏两处即静默失败。
2. **状态层缺失**：`seshat-conflict-local-head-file`（`emacs/seshat-conflict.el:42`）是**单个全局 hash 文件**，多文件同步互相覆盖（写入点 `seshat-conflict.el:87-94` 不按 remote-path 分键）；没有 uid↔path 映射、没有 cursor、没有 dirty/墓碑概念。

`seshat-sync-status`（`emacs/seshat-sync-cmd.el:186`）把相对路径当 uid 传给 `GET /api/progress/{uid}`（`seshat-sync-cmd.el:200-201`）——这是上述两条缺失的直接后果，本计划**不修**它（修在计划 B），但状态库要提供修复所需的 uid 映射能力。

## 事实清单（本轮勘察实测，均带证据）

| # | 事实 | 证据 |
|---|---|---|
| F1 | uid = 26 字符 Crockford Base32（仅大写），客户端不生成；形态非法→`400 invalid_uid`，未登记/墓碑→`404 unknown_uid` | `docs/api.md:69-82` |
| F2 | 全局单游标 `seq`，跨全部根共享；空批次 `next_cursor` 回传请求的 `since`（游标不倒退，重试安全） | `docs/adr/0004`；`docs/api.md` §1.5（约 :92-98，mtime 与 seq 两个 `since` 的区分）与 §9 空批次段 |
| F3 | 无「查最新游标」端点；不带 `since` 等价 `since=0` | `docs/api.md:1119-1122` |
| F4 | 乐观锁只有 `If-Match: "<blob>"`（git blob hash）；全仓**不存在** `base_revision` 字段 | 全仓 `grep base_revision` 零命中 |
| F5 | `changes` 事件只有 9 字段，**不含 `size`/`mtime`** | `internal/api/resources.go:68-76` |
| F6 | `ondemand` 根 `blob` 恒为空串，任何写 → `403 root_read_only` | `docs/api.md:1115-1117` |
| F7 | `GET /api/files` 服务端已支持 `Range`(206)/`If-None-Match`(304)/`416`；**416 响应体是纯文本，不是 JSON** | `internal/api/files.go:159-188`、`docs/api.md:628-630` |
| F8 | `/api/resources?since=` 是 **mtime 秒**，与 `/api/changes?since=` 的 `seq` 语义完全不同；响应无 `next_cursor` | `docs/api.md:84-98` |
| F9 | 墓碑占 `UNIQUE(root,path)`：move 到墓碑路径 → `409` 但物理移动已完成；同路径重建复用原 uid | `docs/api.md:1109-1113`；同路径重建复用原 uid 见 `docs/sync-protocol.md:72` |
| F10 | 现有 4 个同步文件零直接单测；`seshat-rest--request` 被 **4 个** reader 测试文件以 `cl-letf` 桩替（`seshat-reader-annotation-test.el:82-114`、`seshat-reader-annotation-queue-test.el:81`、`seshat-reader-etaf-test.el:382`、`seshat-reader-translate-test.el:663,701`） | `emacs/tests/` 目录仅含 `seshat-reader-*`；桩点清单为实测 grep 结果 |
| F11 | `seshat-rest-token` 从环境变量 `SESHAT_AUTH_TOKEN` 读取，不写入配置文件 | `docs/configuration.md:129-132` |
| F12 | 现有客户端状态文件的惯例位置是 `~/.local/share/seshat/annotation-queue.eld`，原子写 = 同目录临时文件 + rename | `emacs/seshat-reader/seshat-reader-annotation-queue.el:96-97,169-185` |

## 设计

### D1 传输层 `emacs/seshat-transport.el`（新增）

**统一契约**：

```elisp
(defun seshat-transport-request (method url &key body headers timeout)
  "… 成功返回 plist (:status N :headers ALIST :body STRING)；
连接失败返回 (:status nil :error SYMBOL)。")
```

- `:error` 取值：`'connection-failed` / `'timeout` / `'dns-failed`（不抛错，调用方判断 `:status`）。 **分层表述**：transport 层永不抛错（只回报 `:status nil` + `:error` 符号）；抛错责任在 `seshat-rest--request` 薄包装层（见下方「薄包装的失败语义」）。两层语义不矛盾，改动时不得把抛错逻辑上提到 transport。
- 后端开关：`(defcustom seshat-transport-backend 'rest …)`，取值 `rest`（`url.el` + Bearer）或 `webdav`（`curl` + Basic Auth，灰度期保留）。
- **可桩点**：`(defvar seshat-transport--raw nil)`；非 nil 时 `seshat-transport-request` 直接 `funcall` 它（测试注入用，生产为 nil）。
- **纯函数**（可脱离网络单测）：
  - `seshat-transport--parse-url-response (buffer status)` → plist
  - `seshat-transport--parse-curl (exit-code output http-code)` → plist
  - `seshat-transport-header (headers name)` → 大小写不敏感取值（`headers` 为 alist）
- **`seshat-rest--request` 降为薄包装**：签名与返回契约 `(status . body)` **保持不变**，内部改调 `seshat-transport-request`。理由：`emacs/tests/seshat-reader-annotation-test.el` 等 48+ 例以 `cl-letf` 桩替该函数，改契约会让这些测试成批失效，与计划 A 目标无关。

**薄包装的失败语义（M1，硬约束）**：`seshat-rest--request` 现有契约不仅返回 `(status . body)`，还包括「网络错误等异常情形**抛出 error**」（其 docstring 明言），且被 4 处生产调用方硬依赖：`seshat-conflict--remote-head`（`emacs/seshat-conflict.el:80`）、`seshat-conflict--merge-three-way`（`emacs/seshat-conflict.el:186`）、`seshat-reader-annotation--fetch`（`emacs/seshat-reader/seshat-reader-annotation.el:571`，靠 `condition-case` 捕错返回 `--fetch-error` 哨兵）、`seshat-reader-annotation-queue--sync-delete`（`emacs/seshat-reader/seshat-reader-annotation-queue.el:319`，靠 error 停止本轮）。因此薄包装必须：

- transport 返回整数 `:status` → 转回 `(N . BODY)`；
- transport 返回 `:status nil`（含 `:error` 符号）→ **重新 `(error …)` 抛出**，沿用现有文案前缀 `seshat-rest: 请求 %s %s 失败`；
- **不得**把 `(nil . BODY)` 返回给调用方（否则上述 4 处行为退化，且 `--fetch` 会打出与原状不同的错误文案）。

**curl 后端的 body / http_code 分离（M2）**：`-w '%{http_code}'` 默认写 stdout 会污染 body。**实现约定**：`call-process "curl"` 时用 `-s -o <BODY-TEMP-FILE> -w '%{http_code}'`，stdout 只得到 http_code，body 从 `<BODY-TEMP-FILE>` 用 `insert-file-contents-literally` 读回（二进制安全），读完删临时文件。**不得**用「在 stdout 末尾剥最后一行」之类的启发式（body 可能以换行结尾或为二进制）。T1 必须有一例 ERT 断言「body 内容完整且 http_code 正确分离」。

**后端凭据路由（M3）**：

| 后端 | 凭据来源 | 请求头 | 凭据落盘 |
|---|---|---|---|
| `rest` | `seshat-rest-token`（默认取 `(getenv "SESHAT_AUTH_TOKEN")`） | `Authorization: Bearer <token>` | 不落盘（仅内存） |
| `webdav` | `seshat-sync-username` / `seshat-sync-token` | `Authorization: Basic base64(user:token)` | 0600 临时文件，由 transport **内部自实现**等价逻辑；**不调用** `seshat-sync--make-config-file`（它是 `seshat-sync.el` 的私有函数，而本计划承诺该文件零改动） |

**空 token 行为（m2）**：两个后端在 token 为空串时**仍照常发送认证头**（`Bearer ` / `Basic …`），与现状一致——不得因空 token 跳过请求或改为无认证请求。此行为需在 T1 用一例 ERT 固定。

### D2 REST 封装扩展 `emacs/seshat-rest.el`（只增不改）

九个新函数，全部经 `seshat-transport-request`；2xx 之外按服务端契约映射为 plist 字段而非抛错：

| # | 函数 | 端点 | 关键参数 | 返回 / 语义 |
|---|---|---|---|---|
| 1 | `seshat-rest-roots` | `GET /api/roots` | — | `(:status :roots)`，每项 `(:tag :mode :default)` |
| 2 | `seshat-rest-list-resources` | `GET /api/resources` | `root` `prefix` `since` `include-deleted` `limit` | `(:status :items :has-more)` |
| 3 | `seshat-rest-get-resource` | `GET /api/resources/{uid}` | `uid` | `(:status :resource)`；`404` → `:not-found t` |
| 4 | `seshat-rest-changes` | `GET /api/changes` | `since` `limit` | `(:status :changes :next-cursor :has-more)` |
| 5 | `seshat-rest-download-file` | `GET /api/files/{path}` | `root` `if-none-match` | 落盘到 `target`（同目录 temp + rename）；`(:status :etag :content-type :not-modified-p)` |
| 6 | `seshat-rest-upload-file` | `PUT /api/files/{path}` | `content` `root` `if-match` `if-none-match` | `(:status :uid :etag :rev :conflict :read-only-root)` |
| 7 | `seshat-rest-delete-file` | `DELETE /api/files/{path}` | `root` | `(:status :uid :uids)` |
| 8 | `seshat-rest-move-resource` | `POST /api/resources/{uid}/move` | `uid` `to` | `(:status :uid :from :to :conflict :read-only-root)` |
| 9 | `seshat-rest-versions` | `GET /api/versions/{path}` | `path` `blob` | `(:status :head :content)`；用于吸收 `seshat-conflict.el:80,187` 的两处直连 |

**状态码 → 字段映射（必须覆盖，逐条有测试）**：

| 状态码 | 映射 | 备注 |
|---|---|---|
| `200` / `201` | 成功，解析 JSON（文件下载除外） | `201` 表示新建 |
| `304` | `:not-modified-p t` | 无响应体 |
| `401` | `:unauthorized t` | 不重试 |
| `403` | `:read-only-root t` | `ondemand` 根写被拒，不重试 |
| `404` | `:not-found t` | `unknown_uid` / 未登记 |
| `409` | `:conflict 'state-conflict` | 进度时间戳 / move 目标被占 / merge-base 无共同祖先 |
| `412` | `:conflict 'etag-mismatch` | 条件写前提不成立且**内容未被修改** |
| `416` | `:range-not-satisfiable t`，**body 是纯文本，不得按 JSON 解析** | 见 F7 |

URL 构造：`path` 逐段 `url-hexify-string` 但保留 `/`（与 `seshat-conflict--encode-path`（`emacs/seshat-conflict.el:52`）同口径，可复用其思路但**不修改原函数**）；`root` 作为查询参数。

### D3 状态库 `emacs/seshat-state.el`（新增）

**文件**：`(defcustom seshat-state-file (expand-file-name "sync-state.eld" "~/.local/share/seshat/") …)`（与 F12 同目录同风格）。
**原子写**：同目录 `make-temp-file` → `write-region` → `rename-file`（照 `seshat-reader-annotation-queue.el:169-185` 的模式，不调用其函数）。

**数据形状**（单一 plist，`prin1` 序列化）：

```elisp
(:version 1
 :cursor 0
 :roots (("notes" "/abs/local/dir" "mirror") ...)
 :uids (("01J8ZK4Q7M2X9VYB3TR6NDW5PC"
         :root "notes" :path "journal/2026-10-24.org"
         :base-blob "sha1:…" :size 4096 :mtime 1761...
         :dirty nil :deleted-at nil)
        ...)
 :paths ((("notes" . "journal/2026-10-24.org") . "01J8ZK4Q7M2X9VYB3TR6NDW5PC") ...))
```

- `:paths` 是 `:uids` 的派生索引（复合键 `(root . path)`），load 时校验一致性，不一致则以 `:uids` 重建。
- `:base-blob` 取代旧的全局 head 文件（**旧 `~/.emacs.d/seshat-head` 不迁移**，用户 2026-10-24 决定；新状态库首次同步以服务端为准重建 base）。

**API**：

| 函数 | 说明 |
|---|---|
| `seshat-state-load` | 读文件；不存在→空状态；内容非法→空状态 + `warn` 并把坏文件改名为 `.bak`（不静默丢数据） |
| `seshat-state-save` | 原子写；更新 `:version` 与时间戳字段 |
| `seshat-state-get` / `seshat-state-set` | 按 uid 读写条目 |
| `seshat-state-uid-for-path` / `seshat-state-path-for-uid` | 复合键双向查找；后者返回 `(root . path)` |
| `seshat-state-cursor` / `seshat-state-set-cursor` | 全局游标 |
| `seshat-state-set-base-blob` | 记 `(uid blob size mtime)` 并清 dirty |
| `seshat-state-mark-dirty` / `seshat-state-mark-clean` / `seshat-state-dirty-uids` | 脏标记 |
| `seshat-state-mark-deleted` / `seshat-state-deleted-uids` | 墓碑（本地侧） |
| `seshat-state-remap` | rename：改 `:root`/`:path` 并同步 `:paths`（同路径冲突时以新值为准并返回旧值供告警） |
| `seshat-state-set-roots` / `seshat-state-roots` | 根映射（`(tag dir mode)` 三元，`mode` 必须与服务端 `/api/roots` 对齐） |
| `seshat-state--rebuild-paths` / `seshat-state--normalize` | **纯函数**：索引重建、容错加载归一化 |

**`remap` 的冲突语义（M4）**：设 uid A 改名到 `(root . P)`，而 `(root . P)` 原本映射到 uid B：

- `:paths` 的 `(root . P)` 改指 A（新值胜）；
- **B 的 `:uids` 条目中 `:path` 必须置 nil 并标 `:orphan t`**，不得残留旧 `:path`——否则 `--rebuild-paths` 会据 B 的旧 `:path` 把 `(root . P)` 重新指回 B，覆盖新映射（这是双索引设计的数据丢失陷阱）；
- 函数返回 `(:old-uid B :old-path P)` 供调用方告警（计划 B 用 `rescan` 修正本地状态）；
- `--rebuild-paths` 只对 `:path` 非 nil 且无 `:orphan` 的条目建索引。

**墓碑 × dirty × base-blob 的组合语义（M4 附带）**：

- `seshat-state-mark-deleted` 时：置 `:deleted-at` 时间戳、**清 `:dirty`**、**保留 `:base-blob` / `:size` / `:mtime`**（计划 B 做条件删除与「是否需重拉」判断时要用）。
- 墓碑条目**不出现**在 `dirty-uids`，但出现在 `deleted-uids`（供推送删除）。
- `--rebuild-paths` **排除**带 `:deleted-at` 的条目：墓碑不占本地路径。

### D4 与现有代码的边界（硬约束）

- `seshat-rest--request`：**签名与返回契约不变**（`(status . body)`），内部转发 transport。
- `emacs/seshat-rest.el` 顶部增加 1 行 `(require 'seshat-transport)`——这是该文件除 `seshat-rest--request` 函数体改写之外的**唯一改动**。
- `seshat-sync.el` / `seshat-sync-cmd.el` / `seshat-conflict.el`：**零改动**。
- 不新增第三方依赖：只用内置 `url` / `json` / `subprocess` / `files`。
- 不引入自定义 `sqlite`、不引入 `plz`/`request.el` 之类外部 HTTP 库。

## 已知取舍

1. **WebDAV 后端仅做归一化，不修其条件头缺陷**：`/dav` 静默忽略 `If-Match` 是服务端实现限制（`docs/api.md:668-676`），本计划只把它包成统一契约，条件语义仍只有 REST 后端提供。灰度期若走 WebDAV，冲突检测能力劣于 REST——这一点写入 `tech-debt.md`。
2. **状态库不做并发保护**：单 Emacs 进程假设；不做文件锁。多实例（同一用户开两个 daemon）同时同步会互相覆盖，记为已知限制。
3. **`seshat-state.el` 与 `seshat-reader-annotation-queue.el` 的原子写逻辑重复**：两者分属不同模块（阅读器 vs 同步器），本计划不抽公共库，避免把阅读器的依赖方向倒置；若计划 C 出现第三处需要，再抽取。
4. **`:paths` 冗余持久化**：可由 `:uids` 重建，但为降低每次同步的 O(n) 重建成本而持久化；加载时校验一致性。
5. **未处理的代理风险**：`url-retrieve-synchronously` 在 `url-proxy-services` / `http_proxy` 已设时会走代理；本机 `http_proxy` 已设而 `no_proxy` 未设，访问私有 seshat 地址可能被代理吞（本机 WSL2 环境事实：`http_proxy` 已设、`no_proxy` 未设）。这是**既有行为、非本计划引入**，但计划 B 真正联调时必然暴露。本计划只记录，处理方案（transport 层对私有网段绕过代理，或文档提示用户设 `no_proxy`）留给计划 B。

## 任务

### [x] T1 传输层 `seshat-transport.el`

- 动作：① 新建 `emacs/seshat-transport.el`，实现 D1 的契约、两个后端、三个纯函数；② 把 `seshat-rest--request` 改为薄包装（保持返回 `(status . body)`）；③ 新建 `emacs/tests/seshat-transport-test.el`。
- 依赖：无
- 验收：ERT ≥14 例（12 例常规 + 下方标注的 2 例强制断言），覆盖——`seshat-transport-request` 的 method/url/headers/body 构造（桩 `seshat-transport--raw` 或桩 `url-retrieve-synchronously`）；`--parse-url-response` 对 200/304/412 的归一化；`--parse-curl` 对 exit-code 0/28/6/7 与 http-code 的映射；`header` 大小写不敏感取值；连接失败返回 `(:status nil :error …)` 而不抛错。`emacs/tests/seshat-reader-annotation-test.el` 的 48 例**零回归**；另有两例强制断言：① transport 桩返回 `(:status nil :error 'connection-failed)` 时，`seshat-rest--request` **抛出 error**（用 `should-error`）而非返回 `(nil . …)`；② curl 后端在 body 含换行与二进制字节时，`body` 完整返回且 `:status` 取自 `-w '%{http_code}'` 而不污染 body（桩 `call-process`）
- ✅ 2026-10-24 完成：`seshat-transport.el` 388 行 + `seshat-transport-test.el` 29 例；L1 0 warning 0 error（`seshat-rest.el` 原 2 条基线警告因重写消失，非新增）；全仓 399 → 422。额外发现并修复一例桩测试掩盖的真实缺陷（curl 程序名被塞进参数列表导致静默 000）。

### [x] T2 REST 封装扩展 `seshat-rest.el`

- 动作：按 D2 新增 9 个函数（只增不改，`seshat-rest--request` 之外的既有函数一律不动）；新建 `emacs/tests/seshat-rest-test.el`，用桩 transport 断言 URL/参数/状态码映射。**执行时内部分两步串行完成**（单子代理不宜一次做完）：T2a = 函数 1–4（`roots` / `list-resources` / `get-resource` / `changes`）及其测试；T2b = 函数 5–9（`download-file` / `upload-file` / `delete-file` / `move-resource` / `versions`）及其测试
- 依赖：T1
- 验收：ERT ≥25 例，覆盖——9 个函数的 URL 与查询参数构造（含 `path` 编码保留 `/`、`root` 查询参数）；8 行状态码映射各至少 1 例（覆盖 200/201/304/401/403/404/409/412/416 共 9 个状态码，其中 200 与 201 共用一行）；`416` 的纯文本 body **不被当 JSON 解析**（这是必须显式断言的用例）；`changes` 的空批次 `next_cursor` 回传 `since`；`download-file` 落盘而非返回字符串（用临时目录断言文件内容）。
- ✅ 2026-10-24 完成（分 T2a / T2b 两轮）：9 个端点封装 + 统一状态码 helper；`seshat-rest-test.el` 54 例；L1 0 warning；全仓 422 → 503（T2a 后 447、T2b 后 503）。

### [x] T3 状态库 `seshat-state.el`

- 动作：按 D3 新建 `emacs/seshat-state.el` 与 `emacs/tests/seshat-state-test.el`。
- 依赖：T1
- 验收：ERT ≥20 例，覆盖——save/load 往返等值；文件不存在→空状态；内容非法→空状态 + `.bak` 备份（断言原文件被改名而非删除）；`uid-for-path` / `path-for-uid` 双向；`remap` 后 `:paths` 同步更新且返回旧值；dirty/clean 与 `dirty-uids`；墓碑标记与查询；`cursor` 读写；`--rebuild-paths` 纯函数一致性（构造 `:paths` 与 `:uids` 不一致的输入，断言重建结果正确）；原子写（save 后目录无残留临时文件）；另有一例强制覆盖 `remap` 冲突：`(root . P)` 原属 uid B，A 改名为 P 后——断言 `(seshat-state-path-for-uid A)` = `(root . P)`、`(seshat-state-path-for-uid B)` = nil、B 条目带 `:orphan`、`seshat-state--rebuild-paths` 重建后 `(root . P)` 仍指 A（防止双索引回退）
- ✅ 2026-10-24 完成：`seshat-state.el` 490 行 + `seshat-state-test.el` 30 例；L1 0 warning；remap 冲突 / 原子写无残留 / 墓碑不占路径三例强制覆盖。

### [x] T4 传输层二进制保真（T2b 暴露的缺口）

- 动作：`seshat-transport-request` 增 `&key binary`；`seshat-rest-download-file` 传 `:binary t`。
- 依赖：T1、T2
- ✅ 2026-10-24 完成：`rest` 后端（`url.el`）此前按 UTF-8 解码响应体，实测会破坏非 UTF-8 字节（EPUB/PDF）。新增 `--buffer-bytes` 走 unibyte 快路径；`binary` 为 nil 时行为零变化（4 个桩 `seshat-rest--request` 的 reader 套件零回归）。transport 29 例、rest 54 例，全仓 503 → **517**。
- 审查与复盘（2026-10-24）：
  - code-reviewer 判「不通过」，blocking 为「`--url` 对 unibyte 请求体做 `encode-coding-string 'utf-8` 会双重编码、破坏中文与二进制」。**该论断经实测被推翻**：Emacs 的 `encode-coding-string` 对 unibyte 字符串是逐字节直通（实测 `(unibyte-string 80 75 255 0 195)` 经 `'utf-8` 编码后字节序列、长度、`multibyte-string-p` 全部不变，`equal` 原串为 t）。仍按审查意见把分支显式化（`multibyte-string-p` 判断，与 `--curl` 对齐），理由是**不依赖该内部实现细节**，而非修复真实缺陷。
  - 同轮真修的审查项：curl 凭据文件改为「先 chmod 0600 再写内容」并写完复核（major）；`--json-plist` 把 JSON `false`/`null` 规整为 nil（`--json-true-p` 同步收紧）；`--url` docstring 的超时表述纠正；三个测试文件的 `Package-Requires` 统一为 `27.1`。
  - 另登记两条技术债：`seshat-state.el` 单条目写入全量重建 `:paths`（批量 O(n²)）；`--encode-path` 在 `seshat-rest.el` 与 `seshat-conflict.el` 各一份。
  - L2 复跑要求：**必须带齐 14 个 `-L` 目录**（含 straight 的 `gt`/`pdd`/`posframe`/`etaf`/`etaf/lisp`/`etaf-ui`/`ebox`/`ebox/lisp`/`ecss`/`ecss/lisp`/`markdown-mode`/`visual-fill-column`）；缺目录会表现为 `annotation-v8` 2 例 `etaf-ui` file-missing 与 `translate` 整文件加载失败（假失败，非回归）。

## 依赖关系

```
T1 ──┬──▶ T2
     └──▶ T3
```

T1 是两个后端的共同依赖；T2 与 T3 文件不重叠（`seshat-rest.el` 扩展 vs 新建 `seshat-state.el`），**可并行委派**（用户 2026-10-24 确认）。

## 文档清单

| 文档 | 变更域 | 涉及任务 |
|---|---|---|
| `docs/architecture.md` | 在同步章节新增「Emacs 客户端同步分层」小节：transport / rest / state 三层的职责与依赖方向（本计划只写地基部分，引擎部分留给计划 B）。明确「`seshat-rest--request` 保持旧契约作为兼容层」的理由 | T3 后 |
| `docs/configuration.md` | 「Emacs 客户端配置」节新增两个变量：`seshat-transport-backend`（`rest` / `webdav`，灰度期语义）与 `seshat-state-file`（默认 `~/.local/share/seshat/sync-state.eld`） | T3 后 |
| `CHANGELOG.md` | `### 新增` 一条：传输层统一、9 个 REST 封装、同步状态库；**明确标注「内部地基，用户可见同步行为未变」** | T3 后 |
| `openspec/decisions.md` | 两条决策：① 传输分层与 `(status headers body)` 统一契约（含为何保留 `seshat-rest--request` 兼容层）；② 状态库形态（单 `.eld`、per-uid base blob、旧 head 不迁移的理由与代价） | T3 后 |
| `openspec/tech-debt.md` | 两条：① WebDAV 后端条件头仍不生效（灰度期已知，走 WebDAV 时冲突检测劣于 REST）；② 状态库无并发保护（多 daemon 同时同步会互相覆盖） | T3 后 |
| `docs/sync-protocol.md` | 仅改一句：在 §9.1「Android 客户端未接入 `Range`/`If-None-Match`」旁补「Emacs 客户端将在计划 B 接入 `Range`/`If-None-Match`」。§9 的 Emacs 实现清单整体留待计划 B（本计划不实现增量循环，只登记事实） | T3 后 |
| `docs/emacs-reader.md` | 「构建与测试」节的套件清单由 11 个文件更新为 14 个，总例数 399 更新为本计划实测值（≥458） | T3 后 |
| `docs/api.md` / `docs/errors.md` | **不改**（无服务端变更） | — |

## 验证标准

### L1 语法与静态检查

- `cd emacs/seshat-reader && rm -f *.elc && make all` —— 注意：`make all` 只编译 `emacs/seshat-reader/`，新增的三个文件在 `emacs/` 顶层。**必须另外单独字节编译**：`emacs --batch -Q -L emacs -L emacs/seshat-reader -f batch-byte-compile emacs/seshat-transport.el emacs/seshat-state.el emacs/seshat-rest.el 2>&1`，要求 0 error、0 warning（新增文件从零开始，不适用 33 条基线豁免）。
- `check-parens`：三个新/改文件均通过。

### L2 功能验证

- 全仓 ERT **逐文件**运行（既有 11 个文件 + 新增 3 个 = 14 个）。**必须逐文件**：一次加载全部测试文件时 `annotation` / `annotation-queue` 各有 3 个列表用例会因 `etaf-ui` 同时可用而假红（既有基线特性，见 `docs/emacs-reader.md` 构建与测试节）。
- 基线：**399 例**（`page-join` 26、`resize` 80 等）。本计划新增 ≥59 例（T1 ≥14 + T2 ≥25 + T3 ≥20），要求 `unexpected = 0`、`skipped = 0`。
- 14 个 `-L` 目录、跑法脚本见 `docs/emacs-reader.md`「构建与测试」节的 `for` 循环。

### L3 真机手工验收

- **本计划无 L3**：不改变任何用户可见的同步行为（`seshat-sync-now` 仍走原 WebDAV 路径）。L3 验收属计划 B。
- 唯一需要人工确认的是「安装新文件后 Emacs 启动无报错」：`(require 'seshat-transport)` / `(require 'seshat-state)` 各一次不报错。

### 回滚

- 涉及 6 个文件：新增产品文件 2 个（`emacs/seshat-transport.el`、`emacs/seshat-state.el`）、修改 1 个（`emacs/seshat-rest.el` 把 `seshat-rest--request` 改为薄包装）、新增测试文件 3 个（`emacs/tests/seshat-transport-test.el`、`emacs/tests/seshat-rest-test.el`、`emacs/tests/seshat-state-test.el`）。回滚：`git checkout -- emacs/seshat-rest.el` 并删除上述 5 个新增文件。另需删除 `batch-byte-compile` 在 `emacs/` 顶层生成的 `seshat-transport.elc`、`seshat-state.elc`（该目录原本无 `.elc`）；回滚后 `git status` 应只剩已跟踪文件的改动。**无持久化数据需要清理**（状态库文件尚未被任何调用方写入；若测试不小心写到了默认路径，删除 `~/.local/share/seshat/sync-state.eld`）。

## 注意事项

1. **不改 `seshat-sync.el` / `seshat-sync-cmd.el` / `seshat-conflict.el`**——本计划是纯地基，任何对它们的改动都意味着范围失控。
2. **`seshat-rest--request` 的返回契约 `(status . body)` 不得改**：reader 侧 48+ 例测试以它为桩点。
3. **`416` 的响应体是纯文本**：任何「非 2xx 即解析 JSON」的通用错误处理都会在 `416` 上崩，必须显式分支并有测试。
4. **`/api/resources?since=` 是 mtime 秒，`/api/changes?since=` 是 seq**（F8）：两个 `since` 不得共用同一个解析/命名，函数参数名要能区分（建议 `since-seq` / `since-mtime`）。
5. **状态库写入必须原子**：temp + `rename-file`；测试要断言 save 后目录里不留临时文件。
6. **不引入外部 HTTP 库**：只用 `url` / `json` / `subprocess`。引入 `plz` 之类会让 Emacs 版本下限抬升，且与现有 ASCII 风格不符。
7. **测试零网络**：全部通过 `seshat-transport--raw` 桩或 `--parse-*` 纯函数断言；禁止在 ERT 里发起真实请求。
8. **ERT 逐文件跑**，不要一次加载 14 个文件（会 6 例假红，见 L2）。
9. **`make all` 不覆盖顶层 `emacs/*.el`**：新增文件必须单独 `batch-byte-compile` 并达到 0 warning。
