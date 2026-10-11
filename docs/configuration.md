# 配置说明

notes 服务的配置由三部分组成，优先级从低到高：

1. 内置默认值
2. `config.yaml`（可选，文件不存在时全部使用默认值）
3. 环境变量（仅敏感项）

服务通过 `config.Load(path)` 加载配置。敏感值（数据库密钥、API 令牌、LLM API key）禁止写入配置文件或任何落盘文件，只能通过环境变量注入。

## 配置项一览

| 配置项 | YAML 键 | 环境变量 | 默认值 | 敏感 |
|---|---|---|---|---|
| 监听地址 | `server.addr` | — | `":8080"` | 否 |
| 读超时 | `server.read_timeout` | — | `30s` | 否 |
| 写超时 | `server.write_timeout` | — | `30s` | 否 |
| SQLite 路径 | `db.path` | — | `"./data/notes.db"` | 否 |
| 笔记根目录 | `webdav.root` | — | `"./data/notes"` | 否 |
| 公开出口目录 | `webdav.public` | — | `"./data/notes/public"` | 否 |
| 对外出口只读 | `webdav.public_read_only` | — | `false` | 否 |
| 对外出口写扩展名白名单 | `webdav.public_allow_exts` | — | 空（不限制） | 否 |
| 数据库密钥 | 不可配置（不落盘） | `NOTES_DB_KEY` | 空 | **是** |
| API 访问令牌 | 不可配置（不落盘） | `NOTES_AUTH_TOKEN` | 空 | **是** |
| LLM API key | 不可配置（不落盘） | `NOTES_LLM_API_KEY` | 空 | **是** |
| LLM 节点令牌 | 不可配置（不落盘） | `NOTES_NODE_TOKEN` | 空 | **是** |
| 本地 LLM 节点 URL | `llm.local_node_url` | — | 空 | 否 |

说明：

- `read_timeout` / `write_timeout` 使用 Go `time.ParseDuration` 支持的字符串格式（如 `30s`、`1m30s`）。
- `server.addr` 等非敏感项当前仅由配置文件控制；敏感项的 YAML 键被忽略，只能通过环境变量提供。
- `webdav.public_read_only` 只作用于对外公开出口（内部同步通道不受影响）。置为 `true` 后对外出口的全部写操作（PUT/MKCOL/DELETE/MOVE/COPY 等）被拒绝，读操作（GET/PROPFIND/HEAD 等）不受影响。
- `webdav.public_allow_exts` 是允许对外出口写入的文件扩展名白名单（如 `[".org", ".md", ".pdf", ".epub"]`），仅在写文件时校验，读操作不受限制；置空表示不限制扩展名。扩展名比较忽略大小写，前导点可省略。
- 两项同时配置时只读优先：只要 `public_read_only` 为 `true`，任何写操作都被拒绝。
- `NOTES_NODE_TOKEN` 是本地 LLM 处理节点专用令牌（对应 `Config.LLM.NodeToken`），仅保护节点端点（注册 / 轮询 / 回传，最小权限）。未配置时节点端点回退接受主令牌 `NOTES_AUTH_TOKEN`（向后兼容既有单令牌部署）；配置后主令牌不能访问节点端点、节点令牌也不能访问普通端点，二者经 `auth.NodeMiddleware` 相互隔离。

## 敏感值处理

敏感项对应的结构体字段标记为 `yaml:"-"`，因此：

- 无法通过 `config.yaml` 或任何配置文件提供；
- 即使配置文件中出现同名键（如 `db.key`），也会被忽略；
- 序列化（`yaml.Marshal`）时不会输出敏感值。

敏感值只能由部署环境通过环境变量注入：

```bash
export NOTES_DB_KEY=...        # → Config.DB.Key
export NOTES_AUTH_TOKEN=...    # → Config.Auth.Token
export NOTES_LLM_API_KEY=...   # → Config.LLM.CloudAPIKey
export NOTES_NODE_TOKEN=...    # → Config.LLM.NodeToken
```

## 相关文件

- 示例配置：[`config.example.yaml`](../config.example.yaml)
