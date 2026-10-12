# 安全说明

本文件描述 seshat 服务的安全模型：加密、认证、密钥管理与传输安全。
相关文档：[配置说明](configuration.md)、[架构设计](architecture.md)、
[技术债](../openspec/tech-debt.md)。

## 1. 加密模型

采用**静态加密**（服务端可读明文以支持全文索引），分层实施：

| 层 | 机制 | 状态 |
|---|---|---|
| 磁盘层 | LUKS 全盘/分区加密（云 VPS 数据盘） | 部署时启用 |
| 数据库层 | SQLCipher（`internal/storage`，DB 文件级加密） | `-tags "sqlcipher sqlite_fts5"` 启用（见下） |
| 传输层 | TLS（见第 5 节） | 部署时启用 |

### 1.1 磁盘层（LUKS）

云 VPS 上承载 `data/`（数据库、笔记目录、附件对象库）与 git 版本库的数据盘
使用 LUKS 加密。这是当前**兜底的静态加密手段**：即使 DB 层加密未启用，
磁盘离线数据也不可读。解密密钥在实例启动时解锁，不落盘于实例内部。

### 1.2 数据库层（SQLCipher）

SQLite 数据库文件加密由 `github.com/mutecomm/go-sqlcipher/v4` 提供，
`storage.Open(path, key)` 的 `key` 参数即 `SESHAT_DB_KEY`。该库**自带 SQLCipher
amalgamation**（包内 `sqlite3.c` + tomcrypt 源码），编译只需 CGO + gcc，
**无需系统安装 `libsqlcipher-dev`**。存储层按 build tag 选择驱动：

- **启用加密**：以 `-tags "sqlcipher sqlite_fts5"` 构建（`sqlite_fts5` 为迁移 v4
  创建 FTS5 虚表所需；go-sqlcipher 默认未编入 FTS5，缺该 tag 会在运行期报
  `no such module: fts5`），此时 `key` 经 DSN `_pragma_key` → `PRAGMA key`
  对 DB 文件启用加密。
- **无该 tag**：默认构建使用纯 Go 驱动 `modernc.org/sqlite`（明文），非空 key
  被忽略并告警，作为可部署回退。

- 现状：见 [`openspec/tech-debt.md`](../openspec/tech-debt.md)「SQLCipher 降级（已解决）」。
- 加密构建命令：`CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" ./cmd/...`（需 gcc）。
- 影响：未启用加密构建（或构建环境缺 gcc）时，数据库文件为明文，机密性依赖磁盘
  LUKS 兜底。

### 1.3 边界与限制

- 无端到端加密（E2EE）：服务端持有明文以做索引、同步与 LLM 处理。
- 已解密的数据在服务进程内存中可见；威胁模型为「防止磁盘/备份介质离线泄露」，
  而非「防御已攻陷的服务进程」。
- 附件二进制同样落在加密数据盘；对象库按 SHA256 内容寻址，不含额外加密层。

## 2. 认证

单用户模型：客户端身份由**主令牌**统一承担，本地 LLM 处理节点可选使用独立的
**节点令牌**，两类令牌经 `internal/auth` 的 `NodeMiddleware` 相互隔离。

- **主令牌**（`SESHAT_AUTH_TOKEN`）：面向客户端与通用接口。
  - **REST API**：HTTP `Authorization: Bearer <SESHAT_AUTH_TOKEN>`。
  - **WebDAV**：HTTP Basic 认证，用户名任意，**密码为同一个 `SESHAT_AUTH_TOKEN`**
    （对外标准出口与内部同步通道共用该令牌）。
- **节点令牌**（`SESHAT_NODE_TOKEN`，可选）：本地 LLM 处理节点专用，仅保护节点端点
  （注册 / 轮询 / 回传，最小权限）。`auth.NodeMiddleware` 使两类令牌互不越权——
  主令牌访问节点端点返回 `401`，节点令牌访问普通端点也返回 `401`。
  **未配置节点令牌时，节点端点回退接受主令牌**（向后兼容既有单令牌部署；
  此时隔离失效，生产环境建议显式配置节点令牌）。
- 令牌由环境变量注入（见第 3 节），不落盘、不进 git。
- 缺失或错误的令牌返回 `unauthorized`（见 `internal/logging` 错误码），
  不区分「缺失」与「错误」以免泄露信息。

由于是单用户系统，不存在用户注册/吊销流程；轮换令牌即等于更换唯一凭据
（见第 4 节的密钥生命周期）。

## 3. 密钥管理

### 3.1 密钥清单

| 变量 | 用途 | 生成方式 | 来源 |
|---|---|---|---|
| `SESHAT_DB_KEY` | 存储层数据库密钥（32 字节 hex） | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_AUTH_TOKEN` | REST Bearer + WebDAV Basic 令牌 | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_NODE_TOKEN` | 本地 LLM 节点专用令牌（节点端点，最小权限） | `scripts/gen-secrets.sh` | 脚本生成 |
| `SESHAT_LLM_API_KEY` | 云端 LLM API key | 脚本不生成 | LLM 服务商 |

四者均为敏感值，对应结构体字段标记为 `yaml:"-"`，只能通过环境变量注入
（详见 [配置说明](configuration.md)）。

### 3.2 生成

```bash
# 生成到默认路径 ./data/secrets.env（权限 600）
scripts/gen-secrets.sh

# 或指定路径
scripts/gen-secrets.sh /etc/seshat/secrets.env
```

脚本使用 `openssl rand -hex 32` / `openssl rand -base64 32` 生成强随机值，
**不向 stdout 回显任何密钥值**；目标文件已存在时默认拒绝覆盖（`FORCE=1` 可强制），
避免误覆盖导致静态加密数据永久不可恢复。

### 3.3 注入方式

生产环境经 systemd `EnvironmentFile` 注入：

- 单元模板：[`deploy/seshat.service.example`](../deploy/seshat.service.example)
  （`EnvironmentFile=/etc/seshat/secrets.env`，`ExecStart=/usr/local/bin/seshat-server`）。
- 变量模板：[`deploy/seshat.env.example`](../deploy/seshat.env.example)（值为占位符）。
- 部署步骤：`cp deploy/seshat.env.example /etc/seshat/secrets.env` → 填入真实值
  → `chmod 600 && chown root:seshat` → 重启服务。

替代方式：systemd `LoadCredential=`/`credentials` 目录，或在 orchestrator 中挂载
密钥卷；无论哪种方式，密钥值都不得写入单元文件或配置文件。

### 3.4 权限与存放

- 密钥文件权限必须为 `600`，属主为运行服务的专用用户（如 `root:seshat`）。
- 存放位置限定在受保护路径（如 `/etc/seshat/`），不得置于 WebDAV 根目录、
  附件对象库或任何可被 HTTP 读到的目录内。
- 仓库中的 `.gitignore` 排除 `.env`、`.env.*`、`*.env`、`*.key`、`*.pem`、`secrets/`；
  仅 `.example` 后缀的模板可提交，且值必须为占位符。

### 3.5 禁止事项

- 禁止将密钥写入 `config.yaml` 或任何配置文件（同名 YAML 键被忽略）。
- 禁止将密钥文件提交到 git（含临时文件的误提交）。
- 禁止在命令行内联、日志、错误信息或调试输出中回显密钥值。
- 禁止在脚本中用 `${VAR:-default}` 形式探测密钥变量（会把值带进输出）。

## 4. 备份与恢复演练

**核心前提**：静态加密下，**丢失密钥 = 数据永久丢失**。数据盘与备份介质即使
完好，缺少 `SESHAT_DB_KEY`（DB 层加密启用后）与磁盘 LUKS 口令也无法解密。

### 4.1 备份对象

1. 密钥文件（`/etc/seshat/secrets.env`）——必须单独、离线备份。
2. 磁盘 LUKS 口令/头部信息——离线保管，建议多份异地。
3. 数据盘备份（数据库、笔记目录、附件对象库、git 版本库）。

密钥备份与数据备份应**分离存放**：仅拿到其中一份都不可用，降低单点泄露风险。

### 4.2 恢复演练步骤

1. **备份**：将 `secrets.env` 复制到离线介质（加密 U 盘/密码管理器），
   记录备份时间与校验和（`sha256sum`，只记录校验和，不记录值）。
2. **模拟丢失**：在测试实例上删除 `/etc/seshat/secrets.env` 与磁盘挂载，
   确认服务无法启动 / 数据不可读（验证加密确实生效）。
3. **恢复**：从离线介质还原 `secrets.env` 到 `/etc/seshat/`，`chmod 600`；
   解锁磁盘、挂载数据盘、启动服务。
4. **验证**：`systemctl start seshat`，确认服务正常启动、可读取既有笔记与数据库
   （若 DB 层加密已启用，错误 key 应打开失败，正确 key 应成功）。
5. **记录**：在 `openspec/completed/` 或运维日志中记录演练日期、结果与改进项。

建议频率：部署时执行一次完整演练；此后每季度或每次密钥/数据盘变更后复演。

### 4.3 密钥轮换

轮换 `SESHAT_AUTH_TOKEN`：生成新令牌 → 更新 `secrets.env` → 重启服务 →
同步更新各客户端。轮换 `SESHAT_DB_KEY`（DB 层加密启用后）需先解密再以新 key
重加密数据库，属于高风险操作，须在备份完成后执行并立即复演恢复流程。

## 5. 传输安全

- 全链路 TLS：对外 WebDAV、REST API、LLM 云端调用均走 HTTPS/TLS 1.2+；
  VPS 前置于反向代理（如 Nginx/Caddy）终止 TLS，证书用 Let's Encrypt 自动续期。
- 服务进程仅在环回地址监听，由反向代理对外，禁止明文端口直接暴露公网。
- 本地 LLM 处理节点：经 VPN 或仅凭节点令牌 + TLS 访问服务端，不暴露明文端口。
- 客户端侧：桌面 Emacs/Android 均校验服务端证书；Basic/Bearer 凭据只在 TLS
  通道内传输，禁止明文 HTTP。
- HSTS 与安全响应头由反向代理统一设置。
