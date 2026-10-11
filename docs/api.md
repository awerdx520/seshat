# REST API 规范

本文件描述 notes 服务端的**状态同步 REST 接口**（阅读进度、批注）。
文件内容（org/附件/电子书）走 WebDAV，不在此接口范围。
相关文档：[错误码规范](errors.md)、[架构设计](architecture.md)、[安全说明](security.md)。

## 1. 通用约定

| 项 | 约定 |
|---|---|
| Base path | `/api` |
| 认证 | 全部端点要求请求头 `Authorization: Bearer <token>`（令牌即 `NOTES_AUTH_TOKEN`）；缺失或错误返回 `401` |
| 请求体 | `application/json` |
| 响应体 | `application/json; charset=utf-8` |
| 时间格式 | RFC 3339（UTC），如 `2026-10-11T10:00:00Z` |
| 错误体 | `{"error":{"code":"<code>","message":"<message>"}}`，错误码见 [errors.md](errors.md) |

认证失败由公共认证中间件产生：状态 `401`、响应头 `WWW-Authenticate: Bearer`，
响应体为统一 JSON 错误体 `{"error":{"code":"unauthorized","message":"Unauthorized"}}`。

## 2. 端点总览

| 方法 | 路径 | 用途 | 成功状态 |
|---|---|---|---|
| GET | `/api/progress/{document_id}` | 获取阅读进度（支持 `If-Modified-Since` 增量） | 200 / 304 |
| PUT | `/api/progress/{document_id}` | 设置（覆盖）阅读进度 | 200 |
| POST | `/api/annotations` | 创建批注 | 201 |
| GET | `/api/annotations?document_id={id}` | 列出某文档的全部批注 | 200 |
| PUT | `/api/annotations/{id}` | 更新批注 | 200 |
| DELETE | `/api/annotations/{id}` | 删除批注 | 204 |

`{document_id}` 为便于客户端引用的文档标识字符串，由客户端约定，服务端仅按字符串精确匹配、
不做解析。由于它是 URL 路径中的单个路径段，**不能包含 `/`**：建议使用内容哈希或 UUID 等
不含斜杠的稳定标识；若客户端用文件相对路径作标识，须先将其编码为不含斜杠的形式
（如计算 SHA256），否则请求不会匹配到本路由。

## 3. 阅读进度

### 3.1 获取进度

```
GET /api/progress/{document_id}
```

- 请求头（可选）：`If-Modified-Since: <HTTP-date>`——取值为上次响应中的 `updated_at`
  对应的 HTTP 日期格式；若服务端记录的 `updated_at` 不晚于该时间，返回 `304 Not Modified`（无响应体）。
- 成功响应 `200`：

```json
{
  "document_id": "book-1",
  "position": "chapter-3:42",
  "updated_at": "2026-10-11T10:00:00Z"
}
```

- 错误：`401`（未认证）、`404`（该文档尚无进度）、`500`。

```bash
curl -s -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  http://127.0.0.1:8080/api/progress/book-1
```

### 3.2 设置进度

```
PUT /api/progress/{document_id}
```

- 请求体：

```json
{
  "position": "chapter-3:42",
  "updated_at": "2026-10-11T10:00:00Z"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `position` | 是 | 不透明的进度位置字符串（页码、CFI、行号等由客户端定义），不能为空 |
| `updated_at` | 否 | RFC 3339 时间戳；为空时由服务端填当前 UTC 时间 |

- 语义：**后写覆盖**——同一 `document_id` 只保留最新一条进度。
- 成功响应 `200`：返回服务端实际保存的记录（与获取进度同结构，`updated_at` 为规范化后的值）。
- 错误：`400`（`position` 为空或 `updated_at` 非 RFC 3339）、`401`、`500`。

```bash
curl -s -X PUT -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"position":"chapter-3:42","updated_at":"2026-10-11T10:00:00Z"}' \
  http://127.0.0.1:8080/api/progress/book-1
```

## 4. 批注

批注对象结构（创建、更新、列举响应统一）：

```json
{
  "id": 1,
  "document_id": "book-1",
  "location": "chapter-1:10",
  "text": "第一条批注",
  "created_at": "2026-10-11T10:00:00Z",
  "updated_at": "2026-10-11T10:00:00Z"
}
```

### 4.1 创建批注

```
POST /api/annotations
```

- 请求体：

```json
{
  "document_id": "book-1",
  "location": "chapter-1:10",
  "text": "第一条批注"
}
```

`document_id`、`location`、`text` 均必填（不能为空）；`id`、`created_at`、`updated_at`
由服务端生成，请求中无需携带。
- 成功响应 `201`：返回完整批注对象（含服务端分配的 `id`）。
- 错误：`400`（字段为空或请求体非法 JSON）、`401`、`500`。

```bash
curl -s -X POST -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"document_id":"book-1","location":"chapter-1:10","text":"第一条批注"}' \
  http://127.0.0.1:8080/api/annotations
```

### 4.2 列出批注

```
GET /api/annotations?document_id={id}
```

- 成功响应 `200`：批注对象数组，按 `id` 升序；无批注时为 `[]`。

```json
[
  {
    "id": 1,
    "document_id": "book-1",
    "location": "chapter-1:10",
    "text": "第一条批注",
    "created_at": "2026-10-11T10:00:00Z",
    "updated_at": "2026-10-11T10:00:00Z"
  }
]
```

- 错误：`400`（缺少 `document_id` 查询参数）、`401`、`500`。

```bash
curl -s -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  "http://127.0.0.1:8080/api/annotations?document_id=book-1"
```

### 4.3 更新批注

```
PUT /api/annotations/{id}
```

- 请求体（整体替换语义）：

```json
{
  "location": "chapter-1:12",
  "text": "修改后的批注"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `location` | 是 | 新位置，不能为空 |
| `text` | 是 | 新内容，不能为空 |

`document_id` 与 `created_at` 不可修改；`updated_at` 由服务端刷新。
- 成功响应 `200`：返回更新后的完整批注对象。
- 错误：`400`（`id` 非正整数、字段为空或请求体非法 JSON）、`401`、`404`（批注不存在）、`500`。

```bash
curl -s -X PUT -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"location":"chapter-1:12","text":"修改后的批注"}' \
  http://127.0.0.1:8080/api/annotations/1
```

### 4.4 删除批注

```
DELETE /api/annotations/{id}
```

- 成功响应 `204`（无响应体）。
- 错误：`400`（`id` 非正整数）、`401`、`404`（批注不存在）、`500`。

```bash
curl -s -X DELETE -H "Authorization: Bearer $NOTES_AUTH_TOKEN" \
  http://127.0.0.1:8080/api/annotations/1
```

## 5. 错误响应示例

```json
{
  "error": {
    "code": "not_found",
    "message": "阅读进度不存在"
  }
}
```

`code` 为稳定、机器可读的标识（客户端据此分支），`message` 面向用户展示、可能随版本变化。
完整错误码与 HTTP 状态映射见 [errors.md](errors.md)。
