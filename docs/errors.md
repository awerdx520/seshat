# 错误码规范

本文件定义 notes 服务端对外暴露的稳定错误码、HTTP 状态映射与典型产生场景。
相关文档：[REST API 规范](api.md)、[架构设计](architecture.md)、[安全说明](security.md)。

## 1. 错误码与 HTTP 状态映射

错误码定义于 `internal/logging`（`logging.Code` 类型），由 REST 层
（`internal/api`）映射为 HTTP 状态码。

| 错误码 | HTTP 状态 | 含义 | 典型产生场景 |
|---|---|---|---|
| `invalid_argument` | 400 | 请求参数或请求体不合法 | `position`/`document_id`/`location`/`text` 为空；`updated_at` 非 RFC 3339；请求体非法 JSON；批注 `id` 非正整数；缺少 `document_id` 查询参数 |
| `unauthorized` | 401 | 未认证或令牌不正确 | 缺失 `Authorization` 头、scheme 非 `Bearer`/`Basic`、令牌不匹配、服务端未配置令牌 |
| `forbidden` | 403 | 已认证但无权访问该资源 | 预留：路径范围限制等授权策略（当前 REST 端点仅做认证，不产生该码） |
| `not_found` | 404 | 目标资源不存在 | 获取不存在的阅读进度；更新/删除不存在的批注 |
| `conflict` | 409 | 与当前服务端状态冲突 | 预留：同步协议的时间戳冲突检测（当前 REST 端点为后写覆盖，不产生该码） |
| `internal` | 500 | 服务端内部错误 | 数据库读写失败、schema 版本不兼容、响应序列化失败 |

未识别的错误码（含无错误码的普通 error）一律按 `internal` → `500` 处理。

## 2. 错误响应体

REST 错误统一为 JSON（含认证中间件产生的 401）：

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

| 端点 | 可能错误码 |
|---|---|
| `GET /api/progress/{document_id}` | `unauthorized`、`not_found`、`internal` |
| `PUT /api/progress/{document_id}` | `invalid_argument`、`unauthorized`、`internal` |
| `POST /api/annotations` | `invalid_argument`、`unauthorized`、`internal` |
| `GET /api/annotations` | `invalid_argument`、`unauthorized`、`internal` |
| `PUT /api/annotations/{id}` | `invalid_argument`、`unauthorized`、`not_found`、`internal` |
| `DELETE /api/annotations/{id}` | `invalid_argument`、`unauthorized`、`not_found`、`internal` |

## 4. 服务端取码方式（Go）

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
