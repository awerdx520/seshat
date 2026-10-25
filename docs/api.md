# REST API 规范

本文件描述 seshat 服务端对外暴露的 REST 接口全集：状态同步（阅读进度、批注）、
服务端权威身份与增量同步（资源登记、路径解析、根映射、变更流、引用图、维护重扫），
以及既有的版本查询、全文搜索、LLM 任务队列。

文件内容（org / 附件 / 电子书）的两条访问路径：

- **WebDAV**（`/dav/`、`/public/`）：面向文件管理器与笔记客户端的全量镜像；
- **REST 文件端点**（`/api/files/{path...}`）：M7 引入，面向「按需读取」的书库根
  与只需要单片段的客户端（支持 `Range`）。

相关文档：[错误码规范](errors.md)、[同步协议](sync-protocol.md)、
[架构设计](architecture.md)、[安全说明](security.md)、
[ADR-003 uid 身份模型](adr/0003-uid-identity-model.md)、
[ADR-004 增量变更日志](adr/0004-incremental-change-log.md)。

## 1. 通用约定

### 1.1 基址与认证

| 入口 | 路径前缀 | 认证方式 | 说明 |
|---|---|---|---|
| REST API | `/api/` | `Authorization: Bearer <token>` | 主令牌即 `SESHAT_AUTH_TOKEN` |
| 节点端点 | `/api/llm/tasks/poll`、`/api/llm/tasks/{id}/result`、`/api/llm/nodes/register` | `Authorization: Bearer <node-token>` | 节点令牌 `SESHAT_NODE_TOKEN`；未配置时回退主令牌 |
| 内部 WebDAV | `/dav/` | `Authorization: Basic base64(user:token)` | 密码位为令牌，用户名任意 |
| 对外 WebDAV | `/public/` | `Authorization: Basic base64(user:token)` | 同上；受只读/扩展名白名单策略约束 |
| Web UI | `/`、`/static/` | 无 | 浏览器导航无法携带 `Authorization`；页面内脚本用 localStorage 中的令牌调 `/api/*` |

节点端点使用与主令牌**隔离**的认证：节点令牌不能访问普通端点，主令牌在节点令牌
已配置时也不能访问节点端点，实现最小权限隔离。

认证失败的响应由公共中间件产生：状态 `401`、响应头 `WWW-Authenticate`，响应体为
统一 JSON 错误体：

```json
{"error":{"code":"unauthorized","message":"Unauthorized"}}
```

### 1.2 请求与响应

| 项 | 约定 |
|---|---|
| 请求体 | `application/json`（文件写入端点除外，见 §8.2，其请求体为原始字节） |
| 响应体 | `application/json; charset=utf-8`（文件读取端点除外，返回原始字节 + `Content-Type`） |
| 时间格式 | RFC 3339（UTC），如 `2026-10-18T11:00:00Z`；服务端统一规范化为 UTC |
| JSON 请求体上限 | 1 MiB（超出 → `400 invalid_argument`） |
| 文件写入上限 | 32 MiB（超出 → `400 invalid_argument`） |
| 未知 JSON 字段 | 拒绝（`400 invalid_argument`），用于尽早暴露客户端字段拼写错误 |
| 空集合 | 恒为 `[]` 而非 `null` |

### 1.3 统一错误体

除 `GET /api/files` 的 `416`（由标准内容服务产生，响应体为纯文本，见 §8.1）外，
所有错误响应结构一致：

```json
{
  "error": {
    "code": "invalid_uid",
    "message": "uid 格式非法（须为 26 位 Crockford Base32）"
  }
}
```

- `code`：稳定、机器可读的标识（客户端据此分支），完整清单见 §13；
- `message`：面向用户的可读信息，可能随版本调整，**不要**用于分支判断。

### 1.4 身份：uid

M7 起，服务端所有文档标识**一律使用 uid**（客户端不再自行构造文档 id）：

- 形态：26 位 Crockford Base32 大写串，字母表 `0123456789ABCDEFGHJKMNPQRSTVWXYZ`
  （排除易混淆的 `I`/`L`/`O`/`U`），校验正则 `^[0-9A-HJKMNP-TV-Z]{26}$`；
- 由服务端 `crypto/rand` 生成（16 字节 → 26 字符），**客户端不生成 uid**；
- uid 与路径解耦：改名/移动只改 `path`，uid 不变；删除写墓碑（`deleted_at`），uid 不复用；
- 形态非法 → `400 invalid_uid`；形态合法但未登记或已墓碑 → `404 unknown_uid`。

两者分开的价值：客户端据此区分「参数写错」（改参数）与「服务端确实没有该资源」
（重建本地缓存或走变更流补齐）。

> **旧 `document_id` 不再接受**（破坏性变更，详见 §14）。

### 1.5 分页与游标

清单类端点（`/api/resources`、`/api/changes`）采用同一套约定：

| 参数 | 默认 | 范围 | 说明 |
|---|---|---|---|
| `limit` | `500` | 夹紧到 `[1, 2000]` | 非整数 → `400 invalid_argument`；越界值夹紧，不报错 |
| `since` | 资源清单：`0`；变更流：`0` | 整数 | 资源清单为 `mtime >= since`（Unix 秒）；变更流为 `seq > since` |

响应形态：

- `/api/resources` → `{"items":[...],"has_more":bool}`（`has_more` 由「多取一条」判定，
  不提供 offset；继续拉取请提高 `prefix`/`since` 或改用 `/api/changes`）；
- `/api/changes` → `{"changes":[...],"next_cursor":int,"has_more":bool}`（游标单调，
  空批次时 `next_cursor` 回传请求的 `since`，不倒退）。

## 2. 端点总览

| 分组 | 方法 | 路径 | 用途 | 认证 | 成功状态 |
|---|---|---|---|---|---|
| 状态 | GET | `/api/progress/{uid}` | 获取阅读进度（`If-Modified-Since` 增量） | Bearer | 200 / 304 |
| 状态 | PUT | `/api/progress/{uid}` | 设置（覆盖）阅读进度 | Bearer | 200 |
| 状态 | POST | `/api/annotations` | 创建批注（`(uid,kind,location,text)` 幂等） | Bearer | 201 / 200 |
| 状态 | GET | `/api/annotations?uid=` | 列出某文档全部批注 | Bearer | 200 |
| 状态 | PUT | `/api/annotations/{id}` | 更新批注 | Bearer | 200 |
| 状态 | DELETE | `/api/annotations/{id}` | 删除批注 | Bearer | 204 |
| 资源 | GET | `/api/resources` | 列举资源登记（分页 + 过滤） | Bearer | 200 |
| 资源 | GET | `/api/resources/{uid}` | 单个资源的元数据 | Bearer | 200 |
| 资源 | GET | `/api/resolve` | 路径 / `doc_id` → uid | Bearer | 200 |
| 资源 | GET | `/api/roots` | 根映射（`tag`/`mode`/`default`） | Bearer | 200 |
| 文件 | GET | `/api/files/{path...}` | 读文件内容（`Range`/`ETag`/304） | Bearer | 200 / 206 / 304 |
| 文件 | PUT | `/api/files/{path...}` | 写文件（条件写 `If-Match`） | Bearer | 200 / 201 |
| 文件 | DELETE | `/api/files/{path...}` | 删除文件或目录（写墓碑） | Bearer | 200 |
| 文件 | POST | `/api/resources/{uid}/move` | 按 uid 移动/改名 | Bearer | 200 |
| 变更流 | GET | `/api/changes` | 增量变更（全局游标） | Bearer | 200 |
| 引用 | GET | `/api/refs` | 引用图双向查询 | Bearer | 200 |
| 维护 | POST | `/api/resources/rescan` | 全量重扫登记表 | Bearer | 200 |
| 检索 | GET | `/api/search` | 全文检索（FTS5） | Bearer | 200 |
| 版本 | GET | `/api/versions/{path...}` | 文件历史 / 某版本内容 / 两版差异 | Bearer | 200 |
| 版本 | GET | `/api/merge-base` | 两版本共同祖先 | Bearer | 200 |
| 版本 | POST | `/api/revert` | 恢复到历史版本 | Bearer | 200 |
| LLM | POST | `/api/llm/tasks` | 创建 LLM 任务 | Bearer（主令牌） | 201 |
| LLM | GET | `/api/llm/tasks/poll` | 节点轮询领取任务 | Bearer（节点令牌） | 200 / 204 |
| LLM | POST | `/api/llm/tasks/{id}/result` | 节点回传结果 | Bearer（节点令牌） | 204 |
| LLM | POST | `/api/llm/nodes/register` | 节点注册 | Bearer（节点令牌） | 200 |

版本类三个端点仅在服务端装配了版本化仓库时注册；未装配时请求落到 404。
身份/变更/根/文件/引用/重扫六组端点在服务端未启用资源登记时返回
`503 unavailable`（路由表稳定，客户端可区分「能力未就绪」与「端点不存在」）。

## 3. 阅读进度

### 3.1 获取进度

```
GET /api/progress/{uid}
```

- 路径参数：`uid`（26 位 Crockford Base32）；
- 请求头（可选）：`If-Modified-Since: <HTTP-date>`——取值为上次响应 `updated_at`
  对应的 HTTP 日期；若服务端记录的 `updated_at` **不晚于**该时间，返回
  `304 Not Modified`（无响应体）；
- 成功响应 `200`：

```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "position": "chapter-3:42",
  "updated_at": "2026-10-18T11:00:00Z"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `uid` | string | 文档 uid（服务端权威身份） |
| `position` | string | 不透明的进度位置（页码、CFI、行号等由客户端定义） |
| `updated_at` | string | RFC 3339 UTC；服务端规范化后的值 |

- 错误：`400 invalid_uid`（形态非法）、`404 unknown_uid`（uid 未登记/已墓碑，
  仅在服务端启用登记能力时校验）、`404 not_found`（资源存在但尚无进度）、
  `401 unauthorized`、`500 internal`。

```bash
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  http://127.0.0.1:8080/api/progress/01K8Q3M7D2X9V6T1B8N5C0RDEX
```

### 3.2 设置进度

```
PUT /api/progress/{uid}
```

- 请求体：

```json
{
  "position": "chapter-3:42",
  "updated_at": "2026-10-18T11:01:00Z"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `position` | 是 | 不能为空 |
| `updated_at` | 否 | RFC 3339；为空时服务端填当前 UTC（无条件写入） |

- 语义：**后写覆盖**（同一 uid 只保留最新一条）。客户端显式提供 `updated_at` 时做
  时间戳乐观冲突检测：若服务端已存记录的 `updated_at` **晚于**该值，返回
  `409 conflict` 且不覆盖。
- 成功响应 `200`：返回服务端实际保存的记录（结构同 §3.1）。
- 错误：`400 invalid_argument`（`position` 为空、`updated_at` 非 RFC 3339、请求体非法
  或含未知字段）、`400 invalid_uid`、`404 unknown_uid`、`409 conflict`（时间戳落后）、
  `401`、`500`。

```bash
curl -s -X PUT -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"position":"chapter-3:42","updated_at":"2026-10-18T11:01:00Z"}' \
  http://127.0.0.1:8080/api/progress/01K8Q3M7D2X9V6T1B8N5C0RDEX
```

## 4. 批注

批注对象结构（创建、更新、列举响应统一）：

```json
{
  "id": 1,
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "kind": "note",
  "location": "page:12;rect:50.00,100.00,545.50,140.00",
  "text": "第一条批注",
  "selected_text": "被选中的那句原文",
  "created_at": "2026-10-18T11:00:00Z",
  "updated_at": "2026-10-18T11:00:00Z"
}
```

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | int64 | 服务端自增主键（批注自身的标识，非文档标识） |
| `uid` | string | 所属文档 uid；创建后不可修改 |
| `kind` | string | **单维类型**，只表标注类型：约定 `note` / `highlight` / `underline` / `strikeout` / `ink`；缺省 `note`（服务端**不做**枚举校验，未知值原样保存与回传）。与「有无备注」**正交**——加备注不改 `kind`。`bookmark`（书签）是位置标记，**永不**作为 `kind` 取值 |
| `location` | string | 不透明位置串（约定见 §4.5 与 §4.6） |
| `text` | string | **备注维度**：备注正文 / 显示摘要。空串 = 无备注（标记类与手写），非空 = 有备注；`kind=note` 时必非空（便签以备注为本体） |
| `selected_text` | string | 选中原文：标记类（`highlight` / `underline` / `strikeout`）存，其中 `highlight` 必非空；`note` 可空；`ink` 恒空 |
| `created_at` | string | 创建时间（更新时保持不变） |
| `updated_at` | string | 最后更新时间 |

`kind` 与 `selected_text` 自 schema v8 起存在（存量行由迁移的 `DEFAULT` 回填为 `note` / `''`）。**2026-10-25 起 `kind` 的语义收敛为「单维类型」**：`kind` 只回答「这是哪一类标注」，「有没有备注」由 `text` 的空 / 非空回答，「选中的是哪段原文」由 `selected_text` 回答——三者相互正交，**给高亮加备注不改 `kind`**。填充矩阵是客户端约定，服务端只强制「`kind=note` 时 `text` 非空」这一条：

| `kind` | `text` | `selected_text` | 典型来源 |
|---|---|---|---|
| `note` | 备注正文，**必非空** | 选中原文，可为空串 | 页级备注（Android「添加本页备注」产 `note` + `location=page:<n>`，无几何）；Emacs 带前缀 `C-u` 建批注（`note` + `text`=备注 + `selected_text`=选区原文） |
| `highlight` | 空串 | 选中原文，**必非空** | 选中原文、不写备注（Emacs `C-c C-a` 无前缀发 `highlight` + `text=""` + `selected_text`；Android EPUB 选中即此形态；Android PDF 选区） |
| `ink` | 空串 | 空串 | PDF 一笔手写（`page:<n>;ink:...`，见 §4.5.1） |
| `underline` / `strikeout` | 空串（可非空） | 选中原文 | **已定语义、尚未实现**（见下） |

- **`underline` / `strikeout` 已定语义但尚未实现**：服务端**不做枚举校验**，因此这两个值无需服务端改动即可使用；但当前三端都没有产生它们的入口，Android 会把它们归入「其它」分组（行内仍保留原始 `kind`），Emacs 按 `note` 兜底进入列表。
- **加备注不改 `kind`**：`highlight` 条目补备注时只写 `text`（`kind` 保持 `highlight`）；只有「纯页级备注」（无选中原文，如 Android「添加本页备注」）才是 `note`。这一点 PDF 与 EPUB 两端一致（EPUB 早期曾在保存备注时把 `kind` 改写为 `note`，已在 2026-10-25 修正）。

### 4.1 创建批注

```
POST /api/annotations
```

- 请求体：

```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "kind": "note",
  "location": "page:12;rect:50.00,100.00,545.50,140.00",
  "text": "第一条批注",
  "selected_text": "被选中的那句原文"
}
```

必填口径按 `kind` 分支：`uid` 与 `location` 恒必填；**仅 `kind=note`（含 `kind` 缺省）时 `text` 必填**，
`highlight` / `ink` 以及任何未知 `kind` 允许空 `text`。`kind` 缺省为空串时由**存储层兜底为 `note`**
（API 层只作文档说明——请求体反序列化后为空串，显式 `INSERT` 时 SQL 的 `DEFAULT 'note'` 不生效），
兜底发生在校验之前，故缺省 `kind` 的请求不会被误判为「未知 kind 允许空 text」。
`id`、`created_at`、`updated_at` 由服务端生成；`selected_text` 缺省为空串。

**幂等**：服务端按 `(uid, kind, location, text)` 去重（`selected_text` **不参与**键）。命中既有记录时
**不插新行、不刷新 `updated_at`**，直接返回该记录；同 `location` 不同 `kind` 视为两条独立批注。
该语义让客户端的「本地既有批注/笔迹一次性补登」可安全重放（Android 打开带 uid 的书时补登历史笔迹即依赖它）。

- 成功响应：**新建**返回 `201`，**命中幂等键**返回 `200`；两种情况响应体都是完整批注对象。
- 错误：`400 invalid_argument`（`uid`/`location` 为空、`kind=note` 而 `text` 为空、请求体非法）、
  `400 invalid_uid`、`404 unknown_uid`、`401`、`500`。

```bash
curl -s -X POST -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"uid":"01K8Q3M7D2X9V6T1B8N5C0RDEX","location":"page:12;rect:50.00,100.00,545.50,140.00","text":"第一条批注"}' \
  http://127.0.0.1:8080/api/annotations
```

### 4.2 列出批注

```
GET /api/annotations?uid={uid}
```

- 查询参数：`uid`（必填）。
- 成功响应 `200`：批注对象数组，按 `id` 升序；无批注时为 `[]`。
- 错误：`400 invalid_uid`（缺 `uid` 或形态非法）、`404 unknown_uid`、`401`、`500`。

```bash
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  "http://127.0.0.1:8080/api/annotations?uid=01K8Q3M7D2X9V6T1B8N5C0RDEX"
```

### 4.3 更新批注

```
PUT /api/annotations/{id}
```

- 请求体（整体替换 `kind`、`location`、`text` 与 `selected_text`）：

```json
{
  "kind": "note",
  "location": "page:12;rect:50.00,120.00,545.50,160.00",
  "text": "修改后的批注",
  "selected_text": "被选中的那句原文",
  "updated_at": "2026-10-18T11:05:00Z"
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `location` | 是 | 新位置，不能为空 |
| `kind` | 否 | 新形态；缺省为空串时同样由存储层兜底为 `note`（服务端不做枚举校验） |
| `text` | 按 `kind` | **仅 `kind=note` 时必填非空**；`highlight` / `ink` 允许空串 |
| `selected_text` | 否 | 新选中原文，缺省为空串（整体替换语义：不传即清空） |
| `updated_at` | 否 | RFC 3339；非空时既作为新时间戳又用于乐观冲突检测（早于服务端记录 → `409`） |

`uid` 与 `created_at` 不可修改。
- 成功响应 `200`：返回更新后的完整批注对象。
- 错误：`400 invalid_argument`（`id` 非正整数、`location` 为空、`kind=note` 而 `text` 为空、时间戳非法）、
  `404 not_found`（批注不存在）、`409 conflict`（时间戳落后）、`401`、`500`。

```bash
curl -s -X PUT -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"location":"page:12;rect:50.00,120.00,545.50,160.00","text":"修改后的批注"}' \
  http://127.0.0.1:8080/api/annotations/1
```

### 4.4 删除批注

```
DELETE /api/annotations/{id}
```

- 成功响应 `204`（无响应体）。
- 错误：`400 invalid_argument`（`id` 非正整数）、`404 not_found`、`401`、`500`。

```bash
curl -s -X DELETE -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  http://127.0.0.1:8080/api/annotations/1
```

### 4.5 location 约定（PDF）

批注的 `location` 为**不透明字符串**：服务端**不解析**其内容，仅原样保存与回传（跨端语义由各客户端自行约定）。PDF 文档采用如下格式：

```
page:<n>;rect:<x0>,<y0>,<x1>,<y1>
```

- `n` 为 **1-based** 页码。
- `x0,y0,x1,y1` 为矩形四角在**页面坐标**中的值（PDF point 空间，原点在左上、y 轴向下），保留两位小数。
- 坐标**不含缩放**：取自页面坐标系，与客户端当前缩放级别无关，便于跨端复现。
- **不支持已旋转页面**：页面旋转状态存在于客户端渲染器内部，本约定无法表达，旋转页面上采集的坐标会**静默错误**（无报错但位置不再正确）。
- **渲染（M12 起）**：`rect` 段自 M12 起在 Emacs 客户端**会被渲染为页面上的半透明高亮**（缩放/旋转后按同一变换对齐）；`kind` 为 `underline` / `strikeout` 时同一 `rect` 段改绘为细条（见 §4.5.2）。`ink:` 段自 2026-10-25 起在 Emacs 客户端**也会被渲染为页面手写笔迹**（开关 `seshat-reader-annotation-ink-enabled`，默认 `t`；其坐标是页面 pt、与 `rect:` 同空间，见 §4.5.1）。高亮由 C 渲染层在页面位图上绘制（开关 `seshat-reader-annotation-highlight-enabled`，刷新命令 `C-c C-h`），详见 [配置说明](configuration.md) 与 [架构设计](architecture.md)。

示例（第 12 页的矩形区域）：

```
page:12;rect:50.00,100.00,545.50,140.00
```

PDF 的 `location` 是**页锚 + 可选几何尾段**：`page:<n>`（**页锚**）是唯一的跳转真值；第一个 `;` 之后的 `rect:` / `ink:` 段是**可选几何尾段**，只供渲染（Emacs M12 起渲染 `rect:` 高亮，2026-10-25 起渲染 `ink:` 笔迹）与 `seshat:` 引用锚复用，**不参与导航判定**——因此「只有页锚」的 `page:<n>` 是完全合法的形态。共三形态：

| 形态 | 串 | 谁在用 |
|---|---|---|
| 纯页号 | `page:<n>` | Android PDF 文本批注（顶栏「添加批注」按钮与长按菜单「添加本页备注」都走 `PdfReaderActivity.addAnnotation`，只写 `page:<当前页>`）——`text` 承载备注，`location` 只记页。Emacs 侧**不产**此形态：`seshat-reader-annotation--anchor`（页锚 + 几何尾段）恒带 `rect:` |
| 页号 + 矩形 | `page:<n>;rect:<x0>,<y0>,<x1>,<y1>` | Emacs 选区批注（M11.3 起），也是 Emacs M12 高亮的唯一数据来源 |
| 页号 + 笔迹 | `page:<n>;ink:<color>,<widthPt>,...` | Android PDF 手写（见 §4.5.1） |

> **本轮范围**：**Android 侧** PDF 文本批注不产 `rect:`——`PdfReaderActivity.addAnnotation` 只写
> `page:<当前页>` 定页，矩形采集（`rect:`）不在 M10.3 范围内（见 `openspec/tech-debt.md`）。
> **Emacs 侧**文本批注**恒产** `page:<n>;rect:<x0>,<y0>,<x1>,<y1>`（`seshat-reader-annotation--anchor`
> 唯一构造点恒带 `rect:`，即表格第二形态；它同时是 Emacs M12 高亮的唯一数据来源）。

#### 4.5.1 手写笔迹（`ink`）

手写批注复用同一 `location` 字段，靠前缀区分（服务端仍按不透明字符串处理）：

```
page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,<x1>,<y1>,...
```

- **一笔一个批注**（一笔一条 annotation，笔迹过长时分条，便于单笔删除）。
- `color`：`#AARRGGBB`（如 `#FFE53935`）。
- `widthPt`：线宽，**PDF point 空间**，两位小数。
- 点序列：页面坐标（PDF point、原点左上、y 轴向下），两位小数——与 `rect` **同口径**。
- 客户端本地以归一化坐标（相对页面显示矩形的 0..1）存储，上传时按
  `x_pt = nx × page.width`、`y_pt = ny × page.height`、`width_pt = width × page.width` 换算。
- **降级形态**：页面尺寸未知或点序列为空时只发 `page:<n>;ink:<color>,<widthPt>`（不带坐标），
  仍可被解析，「第 n 页手写（0 笔）」不丢批注本体；Android 侧对空点集不登记（不值得上传）。
- **当前状态（2026-10-22）**：Android 已接入同步——`PdfInkStore` 仍是渲染唯一真相，落笔完成时登记一条
  `kind=ink` 的**镜像批注**并随批注队列上行（`InkAnnotationMapper` → `LocationCodec.encodeInk`）；打开带 uid 的书时
  把本地既有笔迹一次性补登，靠服务端 `(uid, kind, location, text)` 幂等去重（§4.1）。
  Emacs 端现已渲染 `ink:` 段（2026-10-25 起，见下条），并按 `kind=ink` 在批注列表里聚合显示（「第 n 页手写（N 笔）」）。
- **Emacs 端渲染（2026-10-25 起）**：`ink:` 段被解析为页面笔迹并交给 C 渲染层的 stroke 入口绘制，开关是
  `seshat-reader-annotation-ink-enabled`（默认 `t`，与 rect 类装饰的 `seshat-reader-annotation-highlight-enabled` 互相独立）。
  **坐标口径**：`ink:` 的点与线宽都是**页面 pt**，与 `rect:` **同一个 page space**（原点左上、y 向下），因此执行端
  **不需要 y 翻转**；点数上限 1024（超出截断为前 1024 点）、颜色只接受恰好 8 位 `#AARRGGBB`，不满足则丢弃整笔。
  契约本身不因渲染实现而改变——服务端仍按不透明字符串原样保存与回传。

#### 4.5.2 多段 `rect:` 契约（字级高亮 / 下划线 / 删除线）

`rect:` 段可以**重复出现多次**，一段一个几何块，顺序即绘制顺序：

```
page:<n>;rect:<x0>,<y0>,<x1>,<y1>;rect:<x0>,<y0>,<x1>,<y1>;...
```

- **为什么多段**：字级高亮把框选结果按行合并成「一行一条」，因此一个批注天然带多段 `rect:`；服务端把它当不透明串保存，**后端零改动**。
- **段数上限**：写入端 **500 段**（Emacs `seshat-reader-annotation--anchor-max-segments`），解析端 **2000 段**（`seshat-reader-annotation--rect-max-segments`）。写入端刻意取更小值留三倍余量：超过解析端上限的段会被静默丢弃（表现为「高亮缺一块」而无任何线索）。超限时 Emacs **只写前 500 段**并提示一次（少画几段是可接受的降级）；`character` 粒度下逐字符矩形可达数千条，因此最容易撞上限，选 `line` 粒度（默认）不受影响。500 段 × 每段约 24 字符约 12 KB，仍远低于 `location` 的 64 KB 长度上限。
- **`rect:` 的语义随 `kind` 而变**（`rect` 只是几何、不含 drawing 语义，跨端读取时**必须按 kind 解释**）：
  - `kind=highlight`：`rect:` 是**填充块**（半透明黄，默认 α 0.35），覆盖整行文字高度的矩形。
  - `kind=underline`：`rect:` 是**细条几何**（行矩形底边高 1.5 pt 的条，不是整行框）；客户端可按自己的描边风格渲染，但不应当作填充块。
  - `kind=strikeout`：同上，细条取行矩形**垂直中线**（上下各 0.75 pt）。
  - `kind=note` / 其它：`rect:` 只作定位参考，Emacs 按 `highlight` 兜底绘制。
  - 即：同一串 `page:3;rect:10.00,20.00,30.00,40.00` 在 `highlight` 下要填满整个框，在 `underline` 下只需画底部那条细线——**框是数据，细条是解释**。
- **跨端现状（2026-10-25）**：Emacs 产多段 `rect:`（字级高亮 + `underline` / `strikeout` 细条）；**Android 仍不产 `rect:`**（PDF 文本批注只写 `page:<n>`，见 §4.5 表格与 `openspec/tech-debt.md`），Android 读多段 `rect:` 时按整体 bbox 或逐段着色自行决定，尚无统一样式约定。

### 4.6 location 约定（EPUB）

EPUB 没有「页」，位置由「章 + 章内字符偏移」表达（`M10.3` 定稿，取代此前「EPUB 待定」）：

```
chapter:<spineIndex>@<startOffset>-<endOffset>
```

- `spineIndex`：**0-based 的 spine 序号**（与 `EpubBook.chapters` / `ViewPager2` 的页序一致）。
- `startOffset` / `endOffset`：**章内字符偏移**，`0-based`、**半开区间** `[start, end)`。
- 偏移单位是 **UTF-16 code unit**（WebView 注入脚本的 `String.length` 与 Kotlin `String.length` 同口径）；
  BMP 之外的字符（emoji 等）在按「字符数」处理的端（如 Emacs）可能 ±1 差异，属已知限制（见 `openspec/tech-debt.md`）。
- 采集方式：`document.body` 文本流的前缀长度（`Range.toString().length` 双向计算），不假定 `end - start == text.length`
  （跨块级元素时浏览器会规范化空白）。
- **退化形态** `chapter-<n>`：偏移不可用时客户端回退为旧形态（只记章、不记偏移），两端解析器都需容忍。
  解析侧只取首段的数字（`chapter:<n>` 前缀），因此**新增字段无需改解析**。

PDF 与 EPUB 的 location 形态并列表：

| 载体 | 形态 | 定页/定位粒度 |
|---|---|---|
| PDF 文本批注（Android） | `page:<n>`（1-based） | 页 |
| PDF 文本批注 / 高亮（Emacs） | `page:<n>;rect:<x0>,<y0>,<x1>,<y1>` | 页 + 页面矩形 |
| PDF 手写（Android） | `page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`（一笔一条） | 页 + 笔迹点列 |
| EPUB | `chapter:<spineIndex>@<startOffset>-<endOffset>` | 章 + 章内字符区间 |
| EPUB（退化） | `chapter-<n>` | 章 |

服务端对所有形态一视同仁：**不解析、只原样保存与回传**，`location` 的跨端语义完全由客户端约定承担（新形态无需服务端改动）。

## 5. 资源登记

资源登记（`resources` 表）是服务端权威的身份映射：`uid` ↔ `(root, path)`。
所有写路径（WebDAV 双出口 + REST 写）都会更新它。

### 5.1 列举资源

```
GET /api/resources?root=&prefix=&since=&include_deleted=&limit=
```

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `root` | string | 全部根 | 根 tag（见 §7） |
| `prefix` | string | 无 | 根内路径段前缀：`prefix=a` 命中 `a` 与 `a/b`，不命中 `ab` |
| `since` | int64 | `0` | 仅返回 `mtime >= since`（Unix 秒）的资源 |
| `include_deleted` | bool | `false` | 是否包含墓碑 |
| `limit` | int | `500` | 夹紧到 `[1, 2000]` |

- 成功响应 `200`：

```json
{
  "items": [
    {
      "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
      "root": "notes",
      "path": "journal/2026-10-18.org",
      "kind": "file",
      "blob": "9f2c1a...e7",
      "rev": "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
      "size": 1024,
      "mtime": 1760785200,
      "created_at": "2026-10-18T08:00:00Z",
      "updated_at": "2026-10-18T11:00:00Z",
      "deleted_at": ""
    }
  ],
  "has_more": false
}
```

> 示例中的 `blob`/`rev` 值为节选（`...` 表示省略中间部分），真实值是 40 位十六进制
> sha1；`seq` 是整数游标。

- 错误：`400 invalid_argument`（`since`/`limit` 非整数、`include_deleted` 非布尔）、
  `503 unavailable`、`401`、`500`。

### 5.2 单资源元数据

```
GET /api/resources/{uid}
```

- 成功响应 `200`：§5.1 中单个 `resourceResponse` 对象。
- 错误：`400 invalid_uid`、`404 unknown_uid`（未登记**或已墓碑**）、
  `503 unavailable`、`401`、`500`。
- 说明：`GET /api/resources/rescan`（错误的动词）会落到本路由，因 `rescan` 不是合法 uid
  而返回 `400 invalid_uid`——重扫只能用 `POST`（见 §11）。

资源对象字段（列表与单项同构）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `uid` | string | 权威身份 |
| `root` | string | 根 tag（逻辑名，如 `notes`、`ebooks`） |
| `path` | string | 根内逻辑相对路径（无前导 `/`） |
| `kind` | string | 资源类型，当前恒为 `file` |
| `blob` | string | 内容 blob hash（mirror 根为 git blob sha1；ondemand 根为空串） |
| `rev` | string | 最后一次登记时的提交 hash（尽力而为，可能为空串） |
| `size` | int64 | 字节数 |
| `mtime` | int64 | 文件 mtime（Unix 秒） |
| `created_at` | string | 首次登记时间（RFC 3339 UTC） |
| `updated_at` | string | 最后更新时间 |
| `deleted_at` | string | 空串表示存活；非空为墓碑时间 |

### 5.3 墓碑语义

- 删除**不物理删登记行**：置 `deleted_at` 并追加 `delete` 事件，`path` 保留删除前值；
- 墓碑对大多数端点等同「不存在」（`404 unknown_uid`）；
- 追溯墓碑：`GET /api/changes`（历史事件）或 `GET /api/resources?include_deleted=true`；
- 墓碑仍占用 `UNIQUE(root, path)`：同一路径重建时**复用原 uid**（复活），因此同一路径
  不会出现第二个 uid。

## 6. 路径解析

```
GET /api/resolve?root={tag}&path={relpath}
GET /api/resolve?doc_id={uid | tag:path | path}
```

两种输入形态**互斥**（都写或都不写 → `400 invalid_argument`）：

| 形态 | 参数 | 解析规则 |
|---|---|---|
| 根 + 路径 | `root` + `path`（两者必须同时提供） | 按 `(root tag, 根内路径)` 精确查登记表 |
| 引用 key | `doc_id` | `tag:path` 时按 `tag` 定根；纯 path 时用**默认根**（首个根） |

`doc_id` 的解析优先级（与 `seshat:` 链接一致）：

1. 形态是合法 uid → 按 uid 直查（墓碑视为不存在）；
2. 含 `:` → 首个冒号前为根 tag、其后为路径；
3. 否则按默认根（`roots[0]`）解释为纯路径。

- 成功响应 `200`（`root`/`path` 取自登记表，即规范化后的权威值）：

```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "root": "notes",
  "path": "journal/2026-10-18.org"
}
```

- 错误：`400 invalid_argument`（参数组合非法、`doc_id` 为空、未设置默认根）、
  `404 unknown_uid`（未登记或已墓碑）、`503 unavailable`、`401`、`500`。

```bash
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  "http://127.0.0.1:8080/api/resolve?doc_id=notes:journal/2026-10-18.org"
```

## 7. 根映射

```
GET /api/roots
```

- 成功响应 `200`：

```json
{
  "roots": [
    {"tag": "notes", "mode": "mirror", "default": true},
    {"tag": "ebooks", "mode": "ondemand", "default": false}
  ]
}
```

| 字段 | 说明 |
|---|---|
| `tag` | 根标识，客户端引用根的键（`tag:relpath` 与 `?root=` 都用它） |
| `mode` | `mirror`（笔记根：WebDAV 全量镜像 + git 版本化 + FTS 索引）或 `ondemand`（书库根：只经 REST 按需读取） |
| `default` | 是否默认根（即 `roots[0]`，客户端省略 `?root=` 时使用） |

**响应绝不包含物理路径**：物理根目录属服务端部署细节，泄露它对客户端无用且扩大
攻击面。客户端只按 `tag` 引用根，路径拼接完全在服务端完成。

- 错误：`503 unavailable`、`401`、`500`。

## 8. 文件读写

### 8.1 读取文件

```
GET /api/files/{path...}?root={tag}
```

- `{path...}`：根内逻辑相对路径（可含 `/`）；非法路径（含 `..`、NUL、空）→ `400`；
- **点路径一律拒绝**：路径任意一段为 `.git`（大小写不敏感）或以 `.` 开头时 → `400
  invalid_argument`。规范化的判定在 REST 与 WebDAV 两侧完全一致（WebDAV 内部出口
  `/dav/` 与对外出口 `/public/` 同样拒绝，返回 `403 Forbidden`），因此 `.git/`、
  `.obsidian/`、`..%2f` 一类路径在任一入口都取不到内容；这不是按根或按认证身份的可配
  选项。
- `root`：缺省为默认根；**读对所有根开放**（书库根按需下载）；未知 tag → `400`；
- **含符号链接的路径（含中间段）一律不可读写**：
  ① 目标自身是符号链接 → 读 `404 not_found`（不读取链接指向的内容）、写 `400
  invalid_argument`（不写穿链接）；
  ② **任意一级父目录（中间段）是符号链接 → `400 invalid_argument`**（读与写同口径）——
  即使该软链指向**根内**也拒绝：`uid ↔ 物理路径`必须一一对应，否则同一实体会有两个
  逻辑路径，登记表只认其中一个，删除/移动/引用图都会出现「改了一个、另一个还在」的幽灵
  条目。悬空软链同样 `400`（不落到 `open(2)` 的 `ENOENT` 变成 `500`）；
  ③ 父目录链解析真实路径后若越出该根的物理目录 → `400 invalid_argument`（兜底：防御
  「检查与使用之间目录被替换」）。越界检查在打开文件之前完成，不存在「先读到再判」的
  窗口。
  上述守卫在**两个出口都生效**：REST 由 `physicalPathChecked` / `rejectSymlinkAncestors`
  实现；WebDAV 的 `/dav/` 与 `/public/` 由 `internal/webdav/symlink.go` 的 `symlinkGuardFS`
  实现，且口径**更严**——不看软链是否指向根内，请求路径的父链或目标自身只要有软链就拒绝，
  客户端看到 `403 Forbidden`（PROPFIND 遍历时该项被静默跳过，不使整次列目录失败）。
- 响应头：`ETag`（带引号的内容 blob hash）、`Content-Type`（按扩展名推断，未知为
  `application/octet-stream`）、`Accept-Ranges: bytes`、`Content-Length`、`Last-Modified`；
- **危险扩展名的强制下载（已实现）**：扩展名属于**主动内容**（`.html` / `.htm` / `.xhtml` /
  `.svg` / `.xml` / `.xsl` / `.js` / `.mjs`，大小写不敏感）时，服务端**强制降级**
  `Content-Type: application/octet-stream` 并加 `Content-Disposition: attachment;
  filename="..."`（文件名取最后一段，引号/反斜杠/控制字符替换为 `_` 以防头注入）——堵住
  「一次 PUT 附件即形成同源存储型 XSS」的路径。其余扩展名按推断类型返回。
- **所有 `GET /api/files` 响应一律带 `X-Content-Type-Options: nosniff`**（含降级为
  `octet-stream` 的情况，防旧版 IE/Edge 忽略类型自行嗅探）。
- 注意：`/api/` 的**其它**响应（JSON 端点与错误响应）仍不带安全头，`X-Frame-Options` /
  CSP 只覆盖 Web UI 页面（见 `docs/security.md` §8.7 第 1 条）。
- **流式传输**：响应体经 Go 标准库的内容服务（`http.ServeContent`）流式写出，不在内存中
  整体读入，大文件（如 EPUB/PDF）按需分块发送，服务端内存占用不随文件大小增长；
- 条件读与区间请求全部由该标准语义处理，服务端不自行解析：`If-None-Match` 命中 →
  `304 Not Modified`（无响应体）；`If-Modified-Since`、`If-Range` 同样按 HTTP 规范生效；
  单区间 `Range`（`bytes=start-end` / `start-` / `-suffix`）→ `206` +
  `Content-Range: bytes start-end/size`；
- 不可满足的 `Range`（语法非法、多区间、起点越界、空文件后缀请求）→ `416` +
  `Content-Range: bytes */size`。**`416` 由标准内容服务产生，响应体不是 JSON 错误结构**
  （不要解析 `{"error":{...}}`）；本服务不产生 `range_not_satisfiable` 错误码，客户端按
  状态码分支即可（见 §13）。
- 错误：`400 invalid_argument`（路径非法、含 `.git`/点段、符号链接父目录越界、目标是
  目录、未知 root）、`404 not_found`（文件不存在或目标自身是符号链接）、
  `503 unavailable`、`401`、`500`。

```bash
# 取前 1 MiB 以供「按需阅读」场景增量渲染
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  -H "Range: bytes=0-1048575" \
  "http://127.0.0.1:8080/api/files/books/compiler.epub?root=ebooks" -o part0.bin
```

### 8.2 写入文件

```
PUT /api/files/{path...}?root={tag}
```

- 请求体为**原始字节**（非 JSON），上限 32 MiB；
- **仅 `mirror` 根可写**：对 `ondemand` 根写入 → `403 root_read_only`（客户端应回退为
  只读展示，而不是重试）；
- **不可写路径**：路径任意一段为 `.git`（大小写不敏感）或以 `.` 开头 → `400
  invalid_argument`（判定与 GET 完全一致，见 §8.1；这是「服务端不写自身元数据目录」的
  硬约束，不能靠客户端自律）；
- **符号链接不可写**：目标自身是符号链接 → `400 invalid_argument`（不写穿链接）；
  父目录链的真实路径越出该根 → `400 invalid_argument`（写入前校验，新建多级父目录时
  同样适用）；
- **WebDAV 出口（`/dav`、`/public`）不支持 `If-Match` / `If-None-Match`**：`x/net/webdav`
  v0.61.0 的 `handlePut` 不解析这两个头，条件头会被**静默忽略**——退化为无条件覆盖，且
  不给客户端任何错误信号（客户端会误以为锁生效）。**需要乐观锁请用 REST `PUT /api/files`**，
  或改用 `ETag` + `GET /api/merge-base` 自行检测冲突。详见 `docs/security.md` §8.8 与
  `openspec/tech-debt.md` 的「WebDAV 出口不支持条件写」。
- 条件写（与 HTTP 条件请求语义一致；`If-Match` 与 `If-None-Match` 同时出现时**两者都
  校验**，任一前提不成立即 `412`，不是二选一）：

| 条件头 | 语义 | 前提不成立时 |
|---|---|---|
| 无 | 无条件写入（不存在则创建，存在则覆盖） | — |
| `If-None-Match: *` | 仅允许创建 | 目标已存在 → `412 etag_mismatch` |
| `If-Match: "<blob>"` / `*` | 仅当当前内容匹配才写入 | 不匹配或不存在 → `412 etag_mismatch`（内容不变） |

- **条件写是原子的**：「读当前 ETag → 比较 → 写文件 → 提交（git commit + 登记）」在同一
  持锁临界区内完成。并发两个带**相同** `If-Match` 的 `PUT` 时，恰好一个成功（`200`），
  另一个得到 `412 etag_mismatch`——不存在「两者都通过校验、后写覆盖前写」的窗口；客户端
  可以据此把 `If-Match` 当真正的乐观锁使用，无需额外协调。
- `If-None-Match: *` 的「已存在」判据是**登记表存活行 ∨ 磁盘文件存在**（两者取或）：
  只要任一成立即 `412`。因此「登记表有行但磁盘文件被旁路删除」「磁盘有文件但登记表被
  手工清理」两种不一致状态都不会被当作「可创建」。
- **空 `If-Match` 永不匹配**：`If-Match: ""`（空强 ETag）与 `If-Match: `（条件头值为空）
  一律不匹配任何内容 → `412 etag_mismatch`，不会被解释为「无条件写」。客户端从空来源（如
  上游返回空 ETag）构造条件头时必须自己兜底，不要发空 ETag 期望「首次写入」。
- 成功响应 `201`（新建）或 `200`（覆盖）：
```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "root": "notes",
  "path": "journal/2026-10-18.org",
  "blob": "9f2c1a...e7",
  "etag": "9f2c1a...e7",
  "rev": "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
  "seq": 1042,
  "created": true
}
```

`etag` 与 `blob` 同值（内容 blob hash），可直接用作下次 PUT 的 `If-Match`；`seq` 为本次
变更事件的游标（见 §9）。

- 错误：`400 invalid_argument`（路径非法、含 `.git`/点段、符号链接目标或父目录越界、
  超过 32 MiB）、`403 root_read_only`、`412 etag_mismatch`、`503 unavailable`、`401`、
  `500`。
- 写顺序固定为「落盘 → git commit → registry」：登记失败时文件已落盘并提交，服务端
  返回 500，由启动 bootstrap 或 `POST /api/resources/rescan` 补登记。

```bash
curl -s -X PUT -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  -H "If-Match: \"9f2c1a...e7\"" \
  --data-binary @note.org \
  "http://127.0.0.1:8080/api/files/journal/2026-10-18.org?root=notes"
```

### 8.3 删除文件或目录

```
DELETE /api/files/{path...}?root={tag}
```

- 仅 `mirror` 根可写（`403 root_read_only`）；
- **不可删路径**：路径任意一段为 `.git`（大小写不敏感）或以 `.` 开头 → `400
  invalid_argument`；目标自身是符号链接 → `400 invalid_argument`（不删穿链接，也不删除
  链接指向的目标）；父目录链真实路径越出该根 → `400 invalid_argument`；
- 目录删除按**路径段边界**收敛：匹配「`path` 恰等于目标」**或**「以 `目标 + '/'` 开头」，
  对子树下**所有存活资源**逐个写墓碑。收敛是精确段边界的，删除 `a/b` 不会误伤 `a/bc`
  或 `a/b-备份` 这类同前缀兄弟资源；
- **符号链接不在登记表中**：登记（bootstrap/rescan）跳过符号链接（见 §8.1），因此目录
  删除的收敛只作用于真实文件，链接本身不会获得墓碑；链接指向的目标若落在该子树内，
  则按普通资源正常处理；
- 成功响应 `200`：

```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "uids": ["01K8Q3M7D2X9V6T1B8N5C0RDEX"],
  "root": "notes",
  "path": "journal/2026-10-18.org",
  "seq": 1043
}
```

`uid` 只在单资源删除（`uids` 长度为 1）时有值；目录删除时为空串，只看 `uids`。

- 错误：`400 invalid_argument`、`403 root_read_only`、`404 unknown_uid`（路径未登记；
  物理文件可能仍在磁盘上，应重新拉取清单而不是重复删除）、`503`、`401`、`500`。

### 8.4 移动 / 改名

```
POST /api/resources/{uid}/move
```

- 请求体：

```json
{"to": "journal/2026/2026-10-18.org"}
```

- `to` 为目标路径（相对**同一个根**，不允许 `..` 逃逸，也不允许 `.git` 段或以 `.` 开头的
  段——判定与 §8.1 同一套规则）；uid 不变，事件为 `rename`（`old_path` 记原路径）；
- **为什么不用 `POST /api/files/{path...}/move`**：Go 1.22 的 `ServeMux` 不允许通配段
  `{path...}` 之后再出现字面量段（注册 `.../{path...}/move` 会在注册期 panic：
  `wildcard not at end`）。因此移动端点以 uid 定位、目标路径放请求体。同一限制也解释了
  为什么版本差异端点写成 `/api/versions/{path...}/diff?from=&to=` 并在 handler 内按尾
  段识别 `diff`（见 §12.2）；
- 成功响应 `200`：

```json
{
  "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
  "root": "notes",
  "from": "journal/2026-10-18.org",
  "to": "journal/2026/2026-10-18.org",
  "seq": 1044
}
```

- 错误：`400 invalid_argument`（`to` 非法或与当前路径相同）、`400 invalid_uid`、
  `403 root_read_only`（资源所属根不可写）、`404 unknown_uid`、`409 conflict`
  （目标路径被其它 uid 占用；**含墓碑占用的情形**，见 §15 已知限制）、`503`、`401`、`500`。

## 9. 变更流

```
GET /api/changes?since={cursor}&limit={n}
```

| 参数 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `since` | int64 | `0` | 只返回 `seq > since` 的事件 |
| `limit` | int | `500` | 夹紧到 `[1, 2000]` |

- 成功响应 `200`：

```json
{
  "changes": [
    {
      "seq": 1042,
      "uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
      "op": "rename",
      "root": "notes",
      "path": "journal/2026/2026-10-18.org",
      "old_path": "journal/2026-10-18.org",
      "blob": "",
      "rev": "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
      "changed_at": "2026-10-18T11:00:00Z"
    }
  ],
  "next_cursor": 1042,
  "has_more": false
}
```

事件字段：

| 字段 | 说明 |
|---|---|
| `seq` | 全局单调递增、不复用的游标（跨全部根共用一个序列） |
| `uid` | 事件主体身份 |
| `op` | `create` / `update` / `rename` / `delete` 四类 |
| `root` | 根 tag |
| `path` | 事件后的路径；`delete` 保留删除前路径 |
| `old_path` | 仅 `rename` 有值（改名前的路径），其余为 `""` |
| `blob` | 内容 blob hash，**尽力而为**：`create`/`update` 取写入后内容的哈希；`rename`/`delete` 沿用登记行既有值；`ondemand` 根恒为空串 |
| `rev` | 提交 hash，**尽力而为**：`create`/`update` 取 commit 后的 HEAD；`rename`/`delete` 沿用登记行既有值；空仓库、未装配仓库或读 HEAD 失败时为空串 |
| `changed_at` | 事件时间（RFC 3339 UTC） |

四类 op 的客户端处理建议：

| op | 处理 |
|---|---|
| `create` | 新增本地记录（若已有同 uid 记录则等价 `update`），按需下载内容 |
| `update` | 更新本地内容与元数据（按 `blob` 判断是否需要重新下载） |
| `rename` | 本地把 `old_path` 重命名到 `path`；uid 不变，进度/批注无需迁移 |
| `delete` | 本地删除（或标记为墓碑），不要立即丢弃 uid 的历史状态 |

游标语义与消费循环：

- `next_cursor` 是本批最后一条事件的 `seq`；空批次时回传请求的 `since`（**游标不倒退**，
  客户端可安全重试）；
- `has_more=true` 表示还有更多事件，应立即用新游标再拉一轮；
- 客户端只需持久化一个整数 `cursor`。

```bash
# 首次（或全量重建后）从 0 开始
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  "http://127.0.0.1:8080/api/changes?since=0&limit=500"
```

```text
# 消费循环（伪代码）
cursor = local_store.load_cursor()      # 首次为 0
loop:
    batch = GET /api/changes?since=cursor&limit=500
    for ev in batch.changes: apply(ev)   # 见上表四类处理
    cursor = batch.next_cursor
    local_store.save_cursor(cursor)
    if not batch.has_more: sleep(poll_interval); continue
```

- 错误：`400 invalid_argument`（`since`/`limit` 非整数）、`503 unavailable`、`401`、`500`。

## 10. 引用

```
GET /api/refs?uid={uid}&direction=in|out
```

| 参数 | 默认 | 说明 |
|---|---|---|
| `uid` | 必填 | 查询主体（形态非法 → `400 invalid_uid`） |
| `direction` | `out` | `out` = 我引用了谁（按 `source_uid`）；`in` = 谁引用了我（按 `target_uid`） |

- 成功响应 `200`：

```json
{
  "refs": [
    {
      "source_uid": "01K8Q3M7D2X9V6T1B8N5C0RDEX",
      "source_location": "",
      "target_uid": "01K8Q3M7D2X9V6T1B8N5C0RDEY",
      "target_location": "chapter-3",
      "created_at": "2026-10-18T11:00:00Z"
    }
  ]
}
```

| 字段 | 说明 |
|---|---|
| `source_uid` | 引用方 uid |
| `source_location` | 引用方内的位置；**当前恒为空串**（源侧位置暂不采集，字段为未来采集保留） |
| `target_uid` | 被引用方 uid |
| `target_location` | 目标内位置（`seshat:` 链接 `#` 之后的部分；无锚点为空串） |
| `created_at` | 该边首次写入时间 |

响应只含引用边，**不含**物理路径与文件内容；需要详情请按 uid 调
`GET /api/resources/{uid}`。

- **单文档引用上限 2000**：一份文档的引用边最多保留 2000 条（`maxRefsPerDocument`），
  超出部分在**写入时**按文本中首次出现的顺序截断——写本身仍然成功（不影响落盘与 commit），
  服务端记一行日志（只含 source uid 与计数）。因此查询端点单次最多返回 2000 条；客户端在
  结果恰为 2000 条时不要假定「这就是全部」，需要完整集合时按 `target_uid`/`source_uid`
  逐条反查，或依赖变更流增量维护本地引用图。

引用来源：`.org` 文件中形如 `seshat:<target>#<loc>` 的链接。`<target>` 有两种形态：

| 形态 | 示例 | 解析 |
|---|---|---|
| uid | `seshat:01K8Q3M7D2X9V6T1B8N5C0RDEX#chapter-3` | 直接按 uid 查 |
| 文档 key | `seshat:notes:journal/2026-10-18.org#chapter-3` | `tag:path` |
| 文档 key | `seshat:journal/2026-10-18.org#chapter-3` | 纯 path（默认根） |

解析优先级与 §6 相同：uid → `tag:path` → 纯 path。**目标解析不到（未登记/已墓碑/非法）
的链接被静默跳过**，不使引用刷新失败、也不产生悬空边。

- 错误：`400 invalid_uid`、`400 invalid_argument`（`direction` 非 `in`/`out`）、
  `404 unknown_uid`（主体未登记或已墓碑）、`503 unavailable`、`401`、`500`。

```bash
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  "http://127.0.0.1:8080/api/refs?uid=01K8Q3M7D2X9V6T1B8N5C0RDEY&direction=in"
```

## 11. 维护：全量重扫

```
POST /api/resources/rescan
```

- 无请求体；
- 用途：修复写钩子漏记（进程崩溃、外部工具直接改盘、钩子失效）。重扫把磁盘现状与
  `resources` 重新对齐，并把漏记的变更补写进 `changes`（客户端仍按游标消费）；
- 并发：同一时刻只允许一次重扫，第二次请求立即返回 `409 rescan_in_progress`
  （**不排队**——维护端点等待会掩盖调用方定时任务重叠的误用）；
- 成功响应 `200`：

```json
{
  "scanned": 1280,
  "created": 3,
  "updated": 12,
  "unchanged": 1264,
  "deleted": 1,
  "failed": 0
}
```

| 字段 | 说明 |
|---|---|
| `scanned` | 本次遍历到的普通文件数（含未变与失败） |
| `created` | 新登记（新生成 uid + `create` 事件） |
| `updated` | 内容有变或墓碑复活（`update` 事件） |
| `unchanged` | 无需变更（不产生事件，游标不推进） |
| `deleted` | 登记中存活但本次未遍历到、已写墓碑的资源数 |
| `failed` | 读元数据或写登记失败的文件数（不阻断整体扫描，重跑即可补齐） |

- 错误：`409 rescan_in_progress`、`503 unavailable`、
  `400 invalid_argument`（如根目录不可读）、`401`、`500`。

```bash
curl -s -X POST -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  http://127.0.0.1:8080/api/resources/rescan
```

## 12. 既有端点

### 12.1 全文检索

```
GET /api/search?q={fts5-query}&limit={n}
```

- `q` 必填，为 FTS5 `MATCH` 表达式；`limit` 可选，**必须是正整数**（与清单类端点不同，
  此处不夹紧，非正整数 → `400`），缺省由索引层取默认上限；
- 成功响应 `200`：命中的文件相对路径（相对仓库根，按相关性排序），无命中为 `[]`：

```json
{"results": ["journal/2026-10-18.org", "sub/b.org"]}
```

- 错误：`400 invalid_argument`（`q` 为空、`limit` 非正整数）、`503 unavailable`
  （未启用索引器）、`401`、`500`。

### 12.2 版本查询

三个语义共用同一条路由 `GET /api/versions/{path...}`，按路径尾段与查询参数分派：

| 语义 | 请求 | 成功响应 |
|---|---|---|
| 文件历史 | `GET /api/versions/{path...}` | `{"head":"<hash>","history":[{"hash","message","when"}]}` |
| 某版本内容 | `GET /api/versions/{path...}?hash={commit}` | `{"hash":"...","content":"..."}` |
| 两版本差异 | `GET /api/versions/{path...}/diff?from={hash}&to={hash}` | `{"diff":"..."}`（unified diff 风格，无差异为空串） |

- 历史按提交时间倒序（新到旧）；仓库尚无提交时为 `{"head":"","history":[]}`；
- 差异端点：缺少 `from`/`to` 或版本无法解析 → `400`；文件在任一版本不存在 → `404`；
- 内容端点：文件在该版本不存在 → `404`；版本无法解析 → `400`；
- 为什么合并为单一路由：`{path...}` 通配段只能是模式末段（`/api/versions/{path...}/diff`
  会 panic），且两段式 `{path}/{hash}` 只匹配两层路径，子目录文件不可达。

### 12.3 共同祖先

```
GET /api/merge-base?a={rev}&b={rev}
```

- 成功响应 `200`：`{"merge_base":"<hash>"}`；
- 错误：`400 invalid_argument`（缺参数、版本无法解析）、`409 conflict`（两者无共同祖先，
  文案固定为「两个版本无共同祖先」——不携带底层 git 错误细节）。

### 12.4 恢复到历史版本

```
POST /api/revert
```

- 请求体：

```json
{"path": "journal/2026-10-18.org", "hash": "4b825dc642cb6eb9a060e54bf8d69288fbee4904"}
```

- 语义：把工作区文件恢复到指定历史版本并追加一次提交（不改写历史；内容已一致时
  不产生新提交）；
- 成功响应 `200`：`{"status":"reverted","hash":"<恢复后的 HEAD>"}`；
- 错误：`400 invalid_argument`（`path`/`hash` 为空、版本无法解析）、
  `404 not_found`（文件在该版本不存在）、`401`、`500`。

### 12.5 LLM 任务与节点

| 端点 | 请求 | 成功响应 | 认证 |
|---|---|---|---|
| `POST /api/llm/tasks` | `{"kind","payload","route"}`（`route` 缺省 `cloud`；`kind`/`payload` 必填） | `201 {"id":1,"status":"pending"}` | 主令牌 |
| `GET /api/llm/tasks/poll` | 无 | `200` 完整任务对象；无待办 → `204` | 节点令牌 |
| `POST /api/llm/tasks/{id}/result` | `{"result","error"}`（`error` 非空 → failed，否则 done） | `204` | 节点令牌 |
| `POST /api/llm/nodes/register` | `{"node_name"}` | `200 {"node_name","status":"registered","registered_at":"..."}` | 节点令牌 |

任务对象（轮询返回）：

```json
{
  "id": 1,
  "kind": "translate",
  "payload": "{\"text\":\"...\"}",
  "route": "local",
  "status": "running",
  "result": "",
  "created_at": "2026-10-18T11:00:00Z",
  "updated_at": "2026-10-18T11:01:00Z"
}
```

- `payload` 为任务请求体的原始 JSON **文本**，对队列透明（由任务类型与执行方解释）；
- 「暂无任务」的 `204` 是轮询的正常结果，不是错误；
- 错误：`400 invalid_argument`（字段为空、`id` 非正整数、请求体非法）、`401`、`500`。

## 13. 错误码表

错误码定义于 `internal/logging/errors.go`（`logging.Code`），由 `internal/api` 的
`statusForCode` 映射为 HTTP 状态；标「handler 内联」的 `unavailable` 不经该映射，由处理器
直接写出对应状态。本表以 `internal/logging/errors.go` 为准。

| 错误码 | HTTP | 含义 | 典型场景 |
|---|---|---|---|
| `invalid_argument` | 400 | 请求参数/请求体不合法 | `position`/`location` 为空；**批注 `kind=note`（含缺省）时 `text` 为空**（`highlight`/`ink` 允许空 `text`，见 §4.1）；`updated_at` 非 RFC 3339；请求体非法 JSON 或含未知字段；超过 1 MiB；`id` 非正整数；`since`/`limit` 非整数；`include_deleted` 非布尔；`root`+`path` 与 `doc_id` 互斥/均缺失；`direction` 非 `in`/`out`；路径含 `..`/NUL/为空；**路径任一段为 `.git`（大小写不敏感）或以 `.` 开头**；**目标自身是符号链接（写路径）或父目录真实路径越出根**；对目录用文件端点；未知根 tag |
| `invalid_uid` | 400 | uid 形态非法（非 26 位 Crockford Base32） | 用旧 `document_id`、含 `I`/`L`/`O`/`U` 或小写、长度不为 26、非 uid 的路径参数（如 `GET /api/resources/rescan`） |
| `unauthorized` | 401 | 未认证或凭证不正确 | 缺失 `Authorization`、scheme 不匹配、令牌错误、服务端未配置令牌 |
| `forbidden` | 403 | 已认证但无权访问 | 预留（当前 REST 端点仅做认证） |
| `root_read_only` | 403 | 目标根不接受写操作 | 对 `ondemand`（书库）根执行 `PUT`/`DELETE`/`move`；移动属于只读根的资源 |
| `not_found` | 404 | 目标资源不存在 | 该 uid 尚无阅读进度；批注 id 不存在；`/api/files` 路径在磁盘上不存在或**目标自身是符号链接**；`/api/revert` 的文件在该版本不存在；版本类端点未装配 |
| `unknown_uid` | 404 | uid 形态合法但未登记或已墓碑 | 资源清单/单资源/解析/引用/状态端点的主体不存在；`/api/files` DELETE 的路径未登记 |
| `conflict` | 409 | 与当前服务端状态冲突 | 进度或批注的 `updated_at` 早于服务端记录；`move` 目标路径被其它 uid（含墓碑）占用；`/api/merge-base` 无共同祖先 |
| `rescan_in_progress` | 409 | 已有一次全量重扫在跑 | 并发调用 `POST /api/resources/rescan`（稍后重试，不要修改请求） |
| `etag_mismatch` | 412 | 条件写的前提不成立，内容未被修改 | `If-Match` 与当前内容不符或资源不存在；`If-None-Match: *` 命中已存在资源 |
| `range_not_satisfiable` | 416 | `Range` 区间不可满足（**M7 修复后由标准内容服务产生**，不再返回 JSON 错误体，仅保留状态码语义） | 区间语法非法、多区间、起点越界、空文件的后缀请求；响应带 `Content-Range: bytes */<size>`，响应体为纯文本。客户端按 `416` 状态码分支，不要解析错误 JSON |
| `internal` | 500 | 服务端内部错误 | 数据库读写失败、schema 版本不兼容、登记失败、序列化失败 |
| `unavailable` | 503 | 能力未就绪（handler 内联） | 未装配资源登记（身份/变更/根/文件/引用/重扫端点）或未启用索引器（`/api/search`） |

未识别或无错误码的错误一律按 `internal` → `500` 处理。

错误响应示例：

```json
{
  "error": {
    "code": "not_found",
    "message": "阅读进度不存在"
  }
}
```

## 14. 破坏性变更说明（M7）

M7（uid 身份与增量同步）对状态 API 做了**不兼容**变更：

| 项 | M7 之前 | M7 之后 |
|---|---|---|
| 文档标识 | `document_id`（客户端自定字符串，可为 `tag:path` 或内容哈希） | `uid`（服务端生成的 26 位 Crockford Base32） |
| 进度端点 | `GET\|PUT /api/progress/{document_id}` | `GET\|PUT /api/progress/{uid}` |
| 批注端点 | `GET /api/annotations?document_id=`、`POST` 请求体 `document_id` | `GET /api/annotations?uid=`、`POST` 请求体 `uid` |
| 响应字段 | `document_id` | `uid` |
| 旧值处理 | — | **不再接受**：形态非法 → `400 invalid_uid`；形态合法但未登记 → `404 unknown_uid` |

服务端不做兼容层：`reading_progress` 与 `annotations` 表按 uid 重建（`document_id` 列已删除）。
客户端获取 uid 的唯一途径是 `GET /api/resolve`（或 `/api/resources`、`/api/changes`）；
不得自行生成 uid。

## 15. 已知限制

以下均为当前实现的客观行为，客户端需据此设计（详细说明见
[同步协议 §10](sync-protocol.md#10-已知限制)）：

1. **移动到被墓碑占用的路径返回 409**：墓碑仍占用 `UNIQUE(root, path)`，`move` 的登记
   步骤会因唯一约束失败返回 `409 conflict`；此时物理移动已完成（写顺序为「落盘 →
   commit → registry」），需用 `POST /api/resources/rescan` 对齐登记。
2. **事件 `rev` 与 `blob` 是尽力而为**：WebDAV `MOVE` 事件不带内容元数据
   （`blob` 空串）、未装配仓库或读 HEAD 失败时 `rev` 为空串。
3. **书库根（`ondemand`）不可写**：`PUT`/`DELETE`/`move` 一律 `403 root_read_only`，
   且其资源 `blob` 恒为空串（不在 git 仓库内，不计算内容哈希）。
4. **`GET /api/resources` 无 offset 分页**：只能通过 `has_more` 判断是否还有更多，
   继续拉取需提高 `prefix`/`since` 或改用变更流。
5. **没有「查询最新游标」的端点**：`GET /api/changes` 不带 `since` 等同于 `since=0`
   （返回最早批次），客户端要得到最新游标只能消费到 `has_more=false`（见
   [同步协议 §10](sync-protocol.md#10-已知限制)）。
6. **单文档引用最多保留 2000 条**：超出部分在写入时被截断（写仍成功，服务端记日志），
   查询端点因此最多返回 2000 条，且不提供「还有更多」标志（见 §10）。

以下限制已在 **M7 修复轮（2026-10-18）**解除，不再作为客户端设计前提（保留记录以免按
旧文档做多余兜底）：

- ~~`GET /api/resources?prefix=` 是未转义 LIKE~~ → 已改为**大小写敏感的精确段边界匹配**
  （`path` 等于 `prefix`，或其前 `len(prefix)+1` 个字符恰为 `prefix + '/'`），`%`/`_`
  不再被当通配符；客户端无需再按 `path` 二次精确过滤；
- ~~`If-Match` 的「读 → 比较 → 写」非原子~~ → 已收进同一临界区（见 §8.2），并发同 ETag
  的写只有一个成功；
- ~~`GET /api/files` 全量读入内存~~ → 已改为流式传输（见 §8.1）。
