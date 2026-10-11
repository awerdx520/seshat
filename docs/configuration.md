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
| 数据库密钥 | 不可配置（不落盘） | `NOTES_DB_KEY` | 空 | **是** |
| API 访问令牌 | 不可配置（不落盘） | `NOTES_AUTH_TOKEN` | 空 | **是** |
| LLM API key | 不可配置（不落盘） | `NOTES_LLM_API_KEY` | 空 | **是** |
| 本地 LLM 节点 URL | `llm.local_node_url` | — | 空 | 否 |

说明：

- `read_timeout` / `write_timeout` 使用 Go `time.ParseDuration` 支持的字符串格式（如 `30s`、`1m30s`）。
- `server.addr` 等非敏感项当前仅由配置文件控制；敏感项的 YAML 键被忽略，只能通过环境变量提供。

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
```

## 相关文件

- 示例配置：[`config.example.yaml`](../config.example.yaml)
