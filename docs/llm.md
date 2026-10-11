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
- 两套**本地**交互机制（同步直连 vs 异步任务队列）的分工与选择依据见下文「后端选择契约」。

## 路由策略

`Router`（`internal/llm/router.go`）持有云端与本地两个 `Client`，按 `Route` 分发：

- **默认云端**：`Router.Chat()` 等价于 `ChatRoute(RouteCloud, …)`。
- **`route=local` 走本地节点**：`ChatRoute(RouteLocal, …)` 调用本地后端。
- 未知 `route` 值一律回退云端。
- 目标后端未配置（为 `nil`）时返回错误（`llm: 云端后端未配置` / `llm: 本地后端未配置`）。

路由规则可配置，默认云端；需本地模型的任务显式标记 `route=local` 即走本地处理节点。

## 后端选择契约

系统并存两套**本地** LLM 交互机制，定位不同、互补而非替代（对应 `openspec/tech-debt.md`
#2）。二者**不互相打通**：同步直连不写队列，异步队列不回调直连，由调用方按场景显式选择。

| 维度 | 同步直连 | 异步任务队列 |
|---|---|---|
| 实现 | `LocalNodeClient`（`internal/llm/local.go`） | `llm_tasks` 表 + `cmd/llmnode` worker（`internal/storage` / `internal/api`） |
| 适用场景 | 本地节点与服务端**同机**；需要**即时**返回结果的短任务 | 本地节点在**另一台机器（家庭网络）**；**长耗时**任务（大文档解析等） |
| 调用方式 | 能力函数传入 `Router`，`route=local` 时同步调用 `{nodeURL}/v1/chat/completions` | 入队 `POST /api/llm/tasks` → 节点轮询领取 → 推理 → 回传 → 客户端异步取 |
| 结果获取 | 调用即返回 | 提交得任务 id，稍后按 id 取结果（异步） |
| 前置条件 | 已显式配置 `llm.local_node_url`（见下） | 有本地节点 worker 轮询该服务端 |
| 失败语义 | 同步返回错误（`llm: 本地后端未配置` / HTTP 错误） | 任务标记 `failed`，原因写入 `result` 列 |

**选择依据**：① 节点与服务端同机、且需即时结果 → 同步直连（能力函数当前走此路径）；
② 节点跨机（家庭网络）或任务长耗时 → 异步任务队列，避免服务端 HTTP 请求长时间挂起。

### 可用性判断 `Router.LocalDirectAvailable`

`internal/llm/backend.go` 提供 `Router.LocalDirectAvailable() bool`，报告「同步直连是否
已配置」：

- 持有**显式配置了 URL** 的 `LocalNodeClient`（`NewLocal("http://…")`）→ `true`；
- `NewLocal("")`（URL 回退默认 `http://localhost:11434`）→ `false`，此时应按「本地节点
  可能不在本机」处理，改用异步入队；
- 未提供本地后端（`NewRouter` 的 `local` 为 `nil`）→ `false`。

> 该方法描述的是「是否显式配置」，不代表 `LocalNodeClient` 不可调用——URL 未配置时它
> 仍会打到默认地址。`route=local` 的实际可路由性仍由 `ChatRoute` 的错误返回判定。

### 异步入队契约 `TaskSubmitter`

`internal/llm` 在 `backend.go` 定义提交接口 `TaskSubmitter`，供「长任务异步入队」使用：

```go
type TaskSubmitter interface {
    SubmitLLMTask(ctx context.Context, kind string, payload []byte, route Route) (int64, error)
}
```

该接口由 `internal/llm` 定义、由 **api 层注入实现**（典型实现包裹
`internal/storage.CreateLLMTask`，完成 `Route` → `route` 字符串与 `[]byte` → payload 字符串
的适配），使 `internal/llm` 不反向依赖 `storage` / `api`。当前能力函数统一走同步直连，
异步入队路径待上层按场景接入。

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
| `NOTES_NODE_TOKEN` | 是 | — | 节点专用令牌（对应 `Config.LLM.NodeToken`，仅可访问节点端点：注册 / 轮询 / 回传，最小权限）；未配置时回退 `NOTES_AUTH_TOKEN` |
| `NOTES_AUTH_TOKEN` | 否 | — | 服务端主访问令牌；仅在未配置 `NOTES_NODE_TOKEN` 时作为节点认证回退（向后兼容既有单令牌部署） |
| `OLLAMA_URL` | 否 | `http://localhost:11434` | 本机 Ollama 根地址 |
| `OLLAMA_MODEL` | 否 | 空 | 默认本地模型名；仅当任务 payload 未自带 `model` 时使用 |
| `NODE_NAME` | 否 | 主机名 | 节点名，注册时上报 |

> **节点令牌 vs 主令牌**：节点（`cmd/llmnode`）访问节点端点（`POST /api/llm/nodes/register`、
> `GET /api/llm/tasks/poll`、`POST /api/llm/tasks/{id}/result`）应使用 `NOTES_NODE_TOKEN`
> （对应服务端 `Config.LLM.NodeToken`，通常经环境变量 `NOTES_NODE_TOKEN` 注入），二者经
> `auth.NodeMiddleware` 与主令牌端点相互隔离（主令牌访问节点端点返回 `401`，节点令牌访问
> 普通端点亦被拒），实现节点与客户端的最小权限隔离。服务端**未配置**节点令牌时，节点端点
> 回退接受主令牌以兼容既有部署；此时 `cmd/llmnode` 也回退使用 `NOTES_AUTH_TOKEN`。

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

1. 启动时用 `NOTES_NODE_TOKEN`（未配置时回退 `NOTES_AUTH_TOKEN`）向 `/api/llm/nodes/register` 注册一次（失败只告警不退出）；
2. 轮询 `GET /api/llm/tasks/poll`；
3. 有任务则调用 `POST {OLLAMA_URL}/v1/chat/completions` 本地推理（payload 约定
   `{"messages":[…], "model"?}`，`model` 缺省回退 `OLLAMA_MODEL`）；
4. `POST /api/llm/tasks/{id}/result` 回传结果；推理失败也回传 `error`，避免任务永远卡在
   `running`；
5. 无任务时休眠数秒（默认 5s）再轮询；收到 `SIGINT` / `SIGTERM` 时优雅退出。

## 相关文件

- 接入层与路由：[`internal/llm/`](../internal/llm/)（`client.go` / `cloud.go` / `local.go` / `router.go` / `backend.go`）
- 能力实现：[`internal/llm/analyze.go`](../internal/llm/analyze.go)、`review.go`、`summarize.go`、`reading.go`、`schedule.go`
- 任务队列数据层：[`internal/storage/llmtask.go`](../internal/storage/llmtask.go)
- 服务端端点：[`internal/api/server.go`](../internal/api/server.go)
- 本地节点 worker：[`cmd/llmnode/`](../cmd/llmnode/)
- 决策记录：[`docs/adr/0002-llm-hybrid-backend.md`](adr/0002-llm-hybrid-backend.md)
