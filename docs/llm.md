# LLM 增值层

LLM 增值层为系统提供文档解析、笔记审查、归纳总结、阅读行为分析与遗忘性复习五类能力。
按 ADR-002（[`docs/adr/0002-llm-hybrid-backend.md`](adr/0002-llm-hybrid-backend.md)）采用
**混合后端**：一般/复杂任务由云端 API 完成，隐私敏感或需本地模型的任务交由家庭机器 /
NAS 上的本地处理节点完成。所有数据统一静态加密，服务端可读明文，无 E2EE。

## 混合后端架构

LLM 能力由两类后端提供，二者都通过统一的 `Client` 接口接入（`internal/llm/client.go`）：

| 后端 | 类型 | 端点 | 认证 | 默认地址 / 模型 |
|---|---|---|---|---|
| 云端 API | `CloudClient` | `{baseURL}/chat/completions` | `Authorization: Bearer <API key>` | `https://api.deepseek.com/v1` / `deepseek-chat` |
| 本地处理节点 | `LocalNodeClient` | `{nodeURL}/v1/chat/completions` | 无（本地节点通常不校验认证） | `http://localhost:11434` / 空（可用 `WithModel` 指定） |

- 两类后端都是 OpenAI 兼容的 `chat/completions` 协议，共用实现 `chatCompletions`，
  差异仅在端点与是否携带 `Authorization` 头。
- `Client` 接口只有 `Chat(ctx, []Message)`；`Message` 为 `{Role, Content}`，`Role` 取值
  `system` / `user` / `assistant`。
- 本包只负责传输与协议适配，不含业务语义；消息内容不经加密（明文传输，TLS 由链路层保证）。

## 路由策略

`Router`（`internal/llm/router.go`）持有云端与本地两个 `Client`，按 `Route` 分发：

- **默认云端**：`Router.Chat()` 等价于 `ChatRoute(RouteCloud, …)`。
- **`route=local` 走本地节点**：`ChatRoute(RouteLocal, …)` 调用本地后端。
- 未知 `route` 值一律回退云端。
- 目标后端未配置（为 `nil`）时返回错误（`llm: 云端后端未配置` / `llm: 本地后端未配置`）。

路由规则可配置，默认云端；需本地模型的任务显式标记 `route=local` 即走本地处理节点。

## 配置项

| 配置项 | 位置 | 默认值 | 敏感 | 说明 |
|---|---|---|---|---|
| `NOTES_LLM_API_KEY` | 环境变量 | 空 | **是** | 云端 LLM API key（→ `Config.LLM.CloudAPIKey`），不落盘、不进 git |
| `llm.local_node_url` | `config.yaml` | 空 | 否 | 本地处理节点 URL；留空表示不启用本地节点 |

> 说明：本地节点 URL 仅通过 YAML 键 `llm.local_node_url` 配置，**没有**对应的环境变量；
> 敏感项对应的结构体字段标记 `yaml:"-"`，只能由环境变量注入。详见
> [`docs/configuration.md`](configuration.md)。

本地处理节点 worker（`cmd/llmnode`）的运行参数全部来自环境变量：

| 环境变量 | 必填 | 默认值 | 说明 |
|---|---|---|---|
| `NOTES_SERVER_URL` | 是 | — | 服务端根地址，如 `https://notes.example.com` |
| `NOTES_AUTH_TOKEN` | 是 | — | 服务端访问令牌（复用单用户认证体系） |
| `OLLAMA_URL` | 否 | `http://localhost:11434` | 本机 Ollama 根地址 |
| `OLLAMA_MODEL` | 否 | 空 | 默认本地模型名；仅当任务 payload 未自带 `model` 时使用 |
| `NODE_NAME` | 否 | 主机名 | 节点名，注册时上报 |

## 能力清单

| 能力 | 入口函数 | 输入 | 输出 |
|---|---|---|---|
| 文档解析分析 | `AnalyzeDocument` | 文档文本 | `DocumentAnalysis`（`Title` / `Sections` / `Terms` / `Entities`） |
| 笔记审查（错误/引用） | `ReviewNotes` | Org 笔记文本 | `ReviewReport`（`Issues[]`：`typo` / `broken_link` / `citation` 等，`Summary`） |
| 归纳总结（摘要/聚类） | `Summarize` / `SummarizeMany` | 单篇文本 / 多篇文本切片 | `Summary`（`Text` / `Tags`） |
| 阅读行为分析 | `AnalyzeReading` | `ReadingInput`（进度数 / 批注数 / 最近批注 / 已完成文档数） | `ReadingInsight`（`Profile` / `Suggestions`） |
| 遗忘性复习（SM-2） | `SM2Next` / `SM2Due` / `GenerateCards` | `SM2State` + 评分（0–5）/ 笔记正文 | 更新后的 `SM2State` / 是否到期 / `[]ReviewCard`（`Question` / `Answer`） |

各能力实现均遵循同一模式：构造带系统提示词的 `[]Message` → `Client.Chat` → 解析回复
（先剥离 Markdown 代码围栏，再截取最外层 JSON），容忍模型在 JSON 前后夹带解释文字。
SM-2 易度因子下限 1.3、默认 2.5，判定「答对」的最低评分为 3。

## 任务队列与节点协议

### 数据表 `llm_tasks`

| 字段 | 说明 |
|---|---|
| `id` | 自增主键 |
| `kind` | 任务类型标签 |
| `payload` | 任务请求体原始 JSON（明文） |
| `route` | 路由目标：`cloud`（默认）或 `local` |
| `status` | 状态机：`pending` → `running` → `done` \| `failed` |
| `result` | 结果正文（`done`）或失败原因（`failed`），明文 |
| `created_at` / `updated_at` | UTC 时间戳（服务端填充） |

存储层操作（`internal/storage/llmtask.go`）：`CreateLLMTask`（入队，`route` 空默认
`cloud`）、`PollLLMTask`（领取最早一条 `route=local` 且 `pending` 的任务并在同一事务内置为
`running`；**无任务返回 `(nil, nil)`**）、`CompleteLLMTask`（回传成功结果）、
`FailLLMTask`（记录失败原因）。`route=cloud` 的任务由服务端直接调用云端 API，不参与节点轮询。

### 服务端端点（`internal/api/server.go`）

| 方法 | 路径 | 说明 | 响应 |
|---|---|---|---|
| `POST` | `/api/llm/tasks` | 创建并入队任务，body `{kind, payload, route?}` | `201` + `{id, status:"pending"}` |
| `GET` | `/api/llm/tasks/poll` | 本地节点轮询领取一条本地任务（置 `running`） | `200` 任务全量 / `204` 无任务（空体） |
| `POST` | `/api/llm/tasks/{id}/result` | 节点回传结果，body `{result}` 或 `{error}` | `204`（`error` 非空则标记 `failed`） |
| `POST` | `/api/llm/nodes/register` | 节点注册，body `{node_name}` | `200` + `{node_name}` |

轮询响应中的任务为对外表示：`{id, kind, payload, route, status, result, created_at, updated_at}`。

### worker 运行循环

`cmd/llmnode`（仅标准库，无外部依赖）：

1. 启动时用 `NOTES_AUTH_TOKEN` 向 `/api/llm/nodes/register` 注册一次（失败只告警不退出）；
2. 轮询 `GET /api/llm/tasks/poll`；
3. 有任务则调用 `POST {OLLAMA_URL}/v1/chat/completions` 本地推理（payload 约定
   `{"messages":[…], "model"?}`，`model` 缺省回退 `OLLAMA_MODEL`）；
4. `POST /api/llm/tasks/{id}/result` 回传结果；推理失败也回传 `error`，避免任务永远卡在
   `running`；
5. 无任务时休眠数秒（默认 5s）再轮询；收到 `SIGINT` / `SIGTERM` 时优雅退出。

## 相关文件

- 接入层与路由：[`internal/llm/`](../internal/llm/)（`client.go` / `cloud.go` / `local.go` / `router.go`）
- 能力实现：[`internal/llm/analyze.go`](../internal/llm/analyze.go)、`review.go`、`summarize.go`、`reading.go`、`schedule.go`
- 任务队列数据层：[`internal/storage/llmtask.go`](../internal/storage/llmtask.go)
- 服务端端点：[`internal/api/server.go`](../internal/api/server.go)
- 本地节点 worker：[`cmd/llmnode/`](../cmd/llmnode/)
- 决策记录：[`docs/adr/0002-llm-hybrid-backend.md`](adr/0002-llm-hybrid-backend.md)
