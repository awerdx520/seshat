# 服务端契约（已迁出）

> 本仓（`seshat`）自 **2026-10-28** 起只包含**客户端**（Emacs + Android）。服务端实现已切分到独立仓库 **keystone**。

## 服务端位置

- 本机仓库路径：`/home/thomas/Workspace/keystone`
- 迁移时 keystone HEAD：`6e4b68e`（36 个提交，2026-10-28）
- 服务端 git 历史：由本仓经 `git filter-repo` 裁剪，仅保留 Go 服务端代码与构建/部署路径

## 契约文档（均在 keystone 仓）

| 文档 | 内容 |
|---|---|
| `docs/api.md` | HTTP 契约（端点、错误码、请求/响应体） |
| `docs/sync-protocol.md` | 增量同步协议（changes 游标、条件写、冲突合并） |
| `docs/errors.md` | 错误码表 |
| `docs/configuration.md` | 服务端配置（`config.yaml` + `KEYSTONE_*` 环境变量） |
| `docs/security.md` | 安全模型（认证、密钥管理、路径安全、WebDAV 沙箱） |
| `docs/architecture.md` | 服务端架构与模块装配骨架（`internal/app` + `internal/module/notes`） |
| `docs/deploy.md` / `docs/backup.md` / `docs/llm.md` | 部署、备份、LLM 节点 |
| `docs/adr/0001–0004` | 服务端相关架构决策记录 |

## 客户端不需要跟随的部分

- **`seshat:` org-link 协议前缀不变**（客户端产出、服务端永久支持）
- **HTTP 契约零变更**（切分未改动任何端点、字段、状态码）
- 客户端配置变量（`seshat-sync-*`、`seshat-rest-*`、`seshat-reader-*` 等）与 Android 包名 `com.seshat.app` 均不变

## 服务端侧改名对照（仅供排查，客户端无需跟随）

| 项 | 旧（seshat） | 新（keystone） |
|---|---|---|
| Go module | `seshat` | `keystone` |
| 二进制 | `seshat-server` / `seshat-llmnode` | `keystone-server` / `keystone-llmnode` |
| 环境变量 | `SESHAT_*` | `KEYSTONE_*` |
| systemd unit | `seshat.service` | `keystone.service` |
| 数据目录 | `./data/seshat*` | `./data/keystone*` |
| git 提交作者 | `seshat <seshat@local>` | `keystone <keystone@local>` |

> 客户端直连服务端时协议与路径不变，仅部署形态发生变化。若需部署/运维，见 keystone 仓的 `docs/deploy.md` 与 `docs/backup.md`。
