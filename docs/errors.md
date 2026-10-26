# 错误码规范

本文件定义 seshat 服务端对外暴露的稳定错误码、HTTP 状态映射与典型产生场景。
相关文档：[REST API 规范](api.md)、[架构设计](architecture.md)、[安全说明](security.md)。

> **M7 起口径**：错误码定义以 [`internal/logging/errors.go`](../internal/logging/errors.go) 为准，HTTP 映射与端点级清单以 [`docs/api.md`](api.md) §13 为准；本文件补充「客户端应当怎么反应」的归纳。所有文档标识已从 `document_id` 切换为 `uid`（破坏性变更，见 `docs/api.md` §14）。

## 1. 错误码与 HTTP 状态映射

错误码定义于 `internal/logging`（`logging.Code` 类型），由 REST 层
（`internal/api`）映射为 HTTP 状态码。

| 错误码 | HTTP 状态 | 含义 | 典型产生场景 |
|---|---|---|---|
| `invalid_argument` | 400 | 请求参数或请求体不合法 | `position`/`uid`/`location` 为空；**批注 `kind=note`（含 `kind` 缺省，服务端兜底为 `note`）时 `text` 为空**——`highlight`/`ink` 以及未知 `kind` 允许空 `text`（服务端**不做** kind 枚举校验，故不能给未知 kind 报错）；`updated_at` 非 RFC 3339；请求体非法 JSON 或含未知字段；超过 1 MiB 或 32 MiB 上限；批注 `id` 非正整数；`since`/`limit` 非整数；`include_deleted` 非布尔；`root`+`path` 与 `doc_id` 互斥/均缺失；`direction` 非 `in`/`out`；路径含 `..`/NUL/为空；**路径任一段为 `.git`（大小写不敏感）或以 `.` 开头**（REST 与 WebDAV 两侧一致）；**写路径的目标自身是符号链接，或父目录真实路径越出根**；对目录用文件端点；未知根 tag |
| `invalid_uid` | 400 | uid 形态非法（非 26 位 Crockford Base32） | 仍用旧 `document_id` 当文档键；含 `I`/`L`/`O`/`U` 或小写；长度不为 26；非 uid 的路径参数（如 `GET /api/resources/rescan`） |
| `unauthorized` | 401 | 未认证或令牌不正确 | 缺失 `Authorization` 头、scheme 非 `Bearer`/`Basic`、令牌不匹配、服务端未配置令牌 |
| `forbidden` | 403 | 已认证但无权访问该资源 | 预留：路径范围限制等授权策略（当前 REST 端点仅做认证，不产生该码） |
| `root_read_only` | 403 | 目标根**不接受写操作**（架构上不该写，不是暂时没权限） | 对 `ondemand`（书库）根执行 `PUT`/`DELETE`/`move`；移动位于只读根下的资源 |
| `not_found` | 404 | 目标资源不存在 | 该 uid 尚无阅读进度；批注 `id` 不存在；`/api/files` 路径在磁盘上不存在，或**目标自身是符号链接**（服务端不跟随链接，见 `docs/api.md` §8.1）；版本类端点未装配仓库 |
| `unknown_uid` | 404 | uid 形态合法但**未登记或已墓碑** | 资源清单/单资源/解析/引用/状态端点的主体不存在；`/api/files` DELETE 的路径未登记 |
| `conflict` | 409 | 与当前服务端状态冲突 | 进度或批注的 `updated_at` **早于**服务端记录（客户端带时间戳时检测）；`move` 目标路径已被其它 uid（含墓碑）占用；`/api/merge-base` 无共同祖先；LLM 任务状态不符 |
| `rescan_in_progress` | 409 | 已有一次全量重扫在进行中 | 并发调用 `POST /api/resources/rescan`（不排队，直接拒绝） |
| `etag_mismatch` | 412 | 条件写的前提不成立，**内容未被修改** | `If-Match` 与当前内容不符或资源不存在；`If-None-Match: *` 命中已存在资源 |
| `range_not_satisfiable` | 416 | `Range` 区间不可满足（**M7 修复后由标准内容服务产生**：仅保留状态码语义，**不再返回 JSON 错误体**，响应体为纯文本 + `Content-Range: bytes */<size>`） | 区间语法非法、多区间、起点越界、空文件的后缀请求。客户端按 `416` 状态码分支，不要解析 `{"error":{...}}` |
| `rate_limited` | 429 | 请求过于频繁 | `POST /api/resources/rescan` 距上一次重扫**结束**不足 60 秒（响应带 `Retry-After: <秒>`；与「正在进行中」的 `409 rescan_in_progress` 是两回事，见下） |
| `internal` | 500 | 服务端内部错误 | 数据库读写失败、schema 版本不兼容、登记失败、根物理路径与版本库根不一致、响应序列化失败 |
| `unavailable` | 503 | 服务端**能力未就绪**（handler 内联） | 未装配资源登记（身份/变更/根/文件/引用/重扫端点）或未启用索引器（`/api/search`） |

未识别的错误码（含无错误码的普通 error）一律按 `internal` → `500` 处理，`statusForCode` 的 `default` 分支即此兜底。

`invalid_uid` 与 `unknown_uid` 分家的价值：前者是**参数写错**（修参数），后者是**服务端确实没有该资源**（重建本地缓存或走变更流补齐）。两者在旧实现里都表现为「查不到这个文档」，但行动完全不同，故不合并。

## 2. 错误响应体

REST 错误统一为 JSON（含认证中间件产生的 401）。**唯一例外**：`GET /api/files` 的 `416`
由标准内容服务（`http.ServeContent`）产生，响应体是纯文本 + `Content-Range: bytes */<size>`，
不是下面的结构——客户端对 `416` 按状态码分支，不要尝试解析错误 JSON。

```json
{
  "error": {
    "code": "invalid_argument",
    "message": "position 不能为空"
  }
}
```

- `code`：稳定标识，见上表；客户端按它分支处理，不要依赖 `message` 文本。
- `message`：面向用户的可读信息，可能随版本调整；不含底层错误细节。

### 2.1 认证失败（401）

认证由 `internal/auth` 的中间件统一返回，响应体与其他 REST 错误一致：

```
HTTP/1.1 401 Unauthorized
WWW-Authenticate: Bearer
Content-Type: application/json; charset=utf-8

{"error":{"code":"unauthorized","message":"Unauthorized"}}
```

即 401 返回 JSON 错误体
`{"error":{"code":"unauthorized","message":"Unauthorized"}}`，并保留
`WWW-Authenticate: Bearer` 响应头；客户端可按 JSON 错误体统一解析。

## 3. 各端点错误码

M7 起状态端点以 **uid** 为文档键（`document_id` 不再接受），身份类端点统一先校验 uid 形态（→ `invalid_uid`）再校验登记（→ `unknown_uid`）。逐端点清单以 `docs/api.md` 为准，下表是按分组归纳：

| 分组 | 端点 | 可能错误码 |
|---|---|---|
| 状态 | `GET /api/progress/{uid}` | `invalid_uid`、`unauthorized`、`unknown_uid`、`not_found`、`internal`（另有 304） |
| 状态 | `PUT /api/progress/{uid}` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`conflict`、`internal` |
| 状态 | `POST /api/annotations` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`internal` |
| 状态 | `GET /api/annotations?uid=` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`internal` |
| 状态 | `PUT /api/annotations/{id}` | `invalid_argument`、`unauthorized`、`not_found`、`conflict`、`internal` |
| 状态 | `DELETE /api/annotations/{id}` | `invalid_argument`、`unauthorized`、`not_found`、`internal` |
| 资源 | `GET /api/resources`、`GET /api/resources/{uid}`、`GET /api/resolve`、`GET /api/roots` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`unavailable`、`internal` |
| 文件 | `GET` / `PUT` / `DELETE` `/api/files/{path...}`、`POST /api/resources/{uid}/move` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`root_read_only`、`etag_mismatch`、`range_not_satisfiable`（仅 GET，且只保留状态码语义）、`unavailable`、`internal` |
| 变更流 | `GET /api/changes` | `invalid_argument`、`unauthorized`、`unavailable`、`internal` |
| 引用 | `GET /api/refs` | `invalid_argument`、`invalid_uid`、`unauthorized`、`unknown_uid`、`unavailable`、`internal` |
| 维护 | `POST /api/resources/rescan` | `unauthorized`、`rate_limited`（距上一次重扫结束不足 60 秒，带 `Retry-After`）、`rescan_in_progress`（已有一次在跑）、`unavailable`、`internal` |

批注相关端点的 `invalid_argument` 按 `kind` 分支（schema v8 起）：`POST /api/annotations` 与
`PUT /api/annotations/{id}` 只要求 `uid`（仅 POST）/ `location` 非空，**`text` 仅在 `kind=note` 时必填**；
`kind` 缺省或空串由存储层兜底为 `note`（兜底先于校验，否则缺省 kind 会被误判）。`kind` 取 `highlight` / `ink`
或任何未知值时允许空 `text`——服务端不做枚举校验，客户端不要指望服务端拒绝未知 `kind`。

## 4. 客户端动作指引

错误码的价值在于决定**下一步动作**，而不只是描述失败。按「能否重试」分成三档：

| 错误码 | 客户端动作 | 重试策略 |
|---|---|---|
| `invalid_argument` | 修正请求参数后重发（不要原样重发） | 不自动重试 |
| `invalid_uid` | 用 `GET /api/resolve?root=&path=`（或 `/api/resources`、`/api/changes`）取真实 uid | 不重试——这是**改参数**问题 |
| `unauthorized` | 修正令牌 / 配置服务端令牌 | 不重试 |
| `forbidden` | 放弃该操作（当前实现仅作预留） | 不重试 |
| `root_read_only` | 放弃写入，回退为只读展示 | **永不**重试——架构上不该写 |
| `not_found` / `unknown_uid` | 先补齐本地数据：拉 `/api/changes` 增量或 `rescan` 后重建缓存 | 不立即重试，先补数据 |
| `conflict` | 重新 `GET` 当前值，按业务规则合并后再写 | 重试前必须先重读 |
| `etag_mismatch` | 重新 `GET` 取新 `ETag`，基于新内容重做改动 | 重试前必须先重读 |
| `rescan_in_progress` | 保持请求体不变，退避后再发 | 可退避重试（指数退避，勿并发） |
| `rate_limited` | **按 `Retry-After` 响应头（秒）退避后重试**，不要立即重发 | 有限次重试；重试不会延长禁用窗口（服务端在 `429` 分支不记录时间戳），也不会消耗后端成本。没有 `Retry-After` 时按 60 秒退避 |
| `range_not_satisfiable` | 放弃 `Range` 请求，改全量 `GET`；或修正区间（该 `416` 响应体不是 JSON 错误结构） | 不重试 |
| `internal` | 记录日志；幂等读可退避重试 | 有限重试（如 2 次） |
| `unavailable` | 视为部署/能力问题（未装配 registry 或索引器）；提示用户或等待运维修复 | 有限退避重试，不要高频轮询 |

## 5. 服务端取码方式（Go）

错误在 `internal/logging` 中以 `*AppError`（错误码 + 可读信息 + 底层错误）传递，
取码需用 `errors.As` 而非 `errors.Is`（错误码是 `Code` 类型常量，不是 error 值）：

```go
var appErr *logging.AppError
if errors.As(err, &appErr) && appErr.Code == logging.ErrNotFound {
    // 映射为 404
}
```

新增错误码时：在 `internal/logging` 增加常量 → 在本文件补充映射与场景 →
在 `internal/api` 的 `statusForCode` 增加 HTTP 状态映射。

例外：`unavailable`（503）由 handler **内联**写出（`internal/api/resources.go`/`rescan.go`/
`server.go` 的能力检查），不经 `statusForCode`，故没有对应的 `logging.Code` 常量。
`range_not_satisfiable`（416）的情况更彻底：M7 修复后 `GET /api/files` 改用标准内容服务
（`http.ServeContent`）流式输出，416 由该标准实现直接产生（**不是**本服务的错误体），
代码中已无该错误码的产生点，表中保留它只为维持状态码语义与既有客户端分支。两者的取值
均以 `docs/api.md` §13 为准。
