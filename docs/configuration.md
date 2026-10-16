# 配置说明

seshat 服务的配置由三部分组成，优先级从低到高：

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
| SQLite 路径 | `db.path` | — | `"./data/seshat.db"` | 否 |
| 笔记根目录 | `webdav.root` | — | `"./data/seshat"` | 否 |
| 公开出口目录 | `webdav.public` | — | `"./data/seshat/public"` | 否 |
| 对外出口只读 | `webdav.public_read_only` | — | `false` | 否 |
| 对外出口写扩展名白名单 | `webdav.public_allow_exts` | — | 空（不限制） | 否 |
| 数据库密钥 | 不可配置（不落盘） | `SESHAT_DB_KEY` | 空 | **是** |
| API 访问令牌 | 不可配置（不落盘） | `SESHAT_AUTH_TOKEN` | 空 | **是** |
| LLM API key | 不可配置（不落盘） | `SESHAT_LLM_API_KEY` | 空 | **是** |
| LLM 节点令牌 | 不可配置（不落盘） | `SESHAT_NODE_TOKEN` | 空 | **是** |
| 本地 LLM 节点 URL | `llm.local_node_url` | — | 空 | 否 |

说明：

- `read_timeout` / `write_timeout` 使用 Go `time.ParseDuration` 支持的字符串格式（如 `30s`、`1m30s`）。
- `server.addr` 等非敏感项当前仅由配置文件控制；敏感项的 YAML 键被忽略，只能通过环境变量提供。
- `webdav.public_read_only` 只作用于对外公开出口（内部同步通道不受影响）。置为 `true` 后对外出口的全部写操作（PUT/MKCOL/DELETE/MOVE/COPY 等）被拒绝，读操作（GET/PROPFIND/HEAD 等）不受影响。
- `webdav.public_allow_exts` 是允许对外出口写入的文件扩展名白名单（如 `[".org", ".md", ".pdf", ".epub"]`），仅在写文件时校验，读操作不受限制；置空表示不限制扩展名。扩展名比较忽略大小写，前导点可省略。
- 两项同时配置时只读优先：只要 `public_read_only` 为 `true`，任何写操作都被拒绝。
- `SESHAT_NODE_TOKEN` 是本地 LLM 处理节点专用令牌（对应 `Config.LLM.NodeToken`），仅保护节点端点（注册 / 轮询 / 回传，最小权限）。未配置时节点端点回退接受主令牌 `SESHAT_AUTH_TOKEN`（向后兼容既有单令牌部署）；配置后主令牌不能访问节点端点、节点令牌也不能访问普通端点，二者经 `auth.NodeMiddleware` 相互隔离。

## 敏感值处理

敏感项对应的结构体字段标记为 `yaml:"-"`，因此：

- 无法通过 `config.yaml` 或任何配置文件提供；
- 即使配置文件中出现同名键（如 `db.key`），也会被忽略；
- 序列化（`yaml.Marshal`）时不会输出敏感值。

敏感值只能由部署环境通过环境变量注入：

```bash
export SESHAT_DB_KEY=...        # → Config.DB.Key
export SESHAT_AUTH_TOKEN=...    # → Config.Auth.Token
export SESHAT_LLM_API_KEY=...   # → Config.LLM.CloudAPIKey
export SESHAT_NODE_TOKEN=...    # → Config.LLM.NodeToken
```

## Emacs 客户端配置（批注侧车）

> 本节为**客户端侧**配置（`notes/emacs/`），与服务端 `config.yaml` / 环境变量无关，不影响服务端行为。

Emacs 端通过 `seshat-reader-annotation` 采集 PDF 页面选区并同步为服务端批注（侧车，不写回 PDF）。相关变量：

| 变量 | 说明 |
|---|---|
| `seshat-reader-annotation-roots` | 书库根映射：`("<标签>" . "<根目录>")` 的 alist。批注的 `document_id` 由 **`<标签>:<相对路径>`** 组成（相对路径 = 文件相对所命中根目录的路径）。多根命中时取**最长**匹配根；文件不在任何根下时降级为 `local:<绝对路径>`，并在提示中说明该批注**不跨端共享**。 |
| `seshat-rest-base-url` | 服务端 REST 基地址（不含末尾斜杠），如 `"https://example.com"`。 |
| `seshat-rest-token` | REST Bearer 令牌（即服务端 `SESHAT_AUTH_TOKEN`）。令牌从环境变量 `SESHAT_AUTH_TOKEN` 读取（`(getenv "SESHAT_AUTH_TOKEN")`），**不得写入配置文件**。 |

配置示例：

```elisp
(setq seshat-rest-base-url "https://example.com"
      seshat-rest-token (or (getenv "SESHAT_AUTH_TOKEN") "")
      seshat-reader-annotation-roots '(("ebook" . "~/WorkSpace/e-book/")))
```

### 阅读器翻译 / 解释（go-translate 预设）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-translate` 模块读取），与服务端无关。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-translate-preset` | `reader` | 「翻译」使用的 gt 预设名（阅读器按名从 `gt-preset-translators` 取用） |
| `seshat-reader-translate-explain-preset` | `reader-explain` | 「解释」使用的 gt 预设名（通常指向 `gt-chatgpt-engine`） |
| `seshat-reader-translate-fallback-langs` | `(en zh)` | 语言回退：源语言取本列表首项，目标语言由此推导（可由命令前缀参数覆盖） |
| `seshat-reader-translate-render` | `pop` | posframe 呈现方式：`pop`（弹出，超时自动消失）或 `pin`（固定停留） |

说明：

- `reader` / `reader-explain` 两个 gt 预设**需在用户配置侧定义**（示例见 `thomas-emacs/lisp/init-tools.el`）；阅读器侧只按预设名取用，缺失时回退内置默认（翻译回退 youdao/google，解释需显式配置端点）。
- gt 的 key（如 `gt-chatgpt-key`）**一律走 authinfo / 环境变量**（本项目经 `DEEPSEEK_API_KEY` 环境变量注入），**禁止写入配置文件**。

### 批注离线队列（服务不可用时的本地暂存）

> 与批注侧车同属**客户端侧**配置（由 `seshat-reader-annotation-queue` 模块读取），与服务端无关。

服务端不可用时，批注的创建/删除不再报错，而是写入本地队列暂存；服务端恢复后自动推进同步。

| 变量 | 默认值 | 说明 |
|---|---|---|
| `seshat-reader-annotation-queue-file` | `~/.local/share/seshat/annotation-queue.eld` | 离线队列文件路径 |
| `seshat-reader-annotation-queue-auto-sync` | `t` | 是否启用自动同步（服务恢复后自动推进） |
| `seshat-reader-annotation-queue-sync-interval` | `300` | 周期同步间隔（秒） |
| `seshat-reader-annotation-queue-initial-delay` | `10` | Emacs 启动后首次自动同步的延迟（秒） |
| `seshat-reader-annotation-queue-max-entries` | `1000` | 队列条目上限（达上限时拒绝入队） |

说明：

- 服务端不可用时，批注/删除操作写入本地队列（**不报「服务不可用」**）；用户得到的是「已存入本地，待联网同步」。批注**列表**在离线时仍显示本地待同步项并标 `[待同步]`。
- 服务恢复后，同步由以下时机推进：**启动后 `initial-delay`（默认 10 秒）首次 + 每 `sync-interval`（默认 300 秒）周期 + 手动 `M-x seshat-reader-annotation-queue-sync` + `list`/`create` 成功后的机会性同步**。
- 队列文件为 elisp 数据（`prin1` 写出的 plist 列表），采用**原子写**：先把内容写入同目录唯一临时文件，再 `rename-file` 原子覆盖目标文件，避免写入中途崩溃留下损坏内容；读取到损坏文件时保留原文件不覆盖并报错。

## 相关文件

- 示例配置：[`config.example.yaml`](../config.example.yaml)
