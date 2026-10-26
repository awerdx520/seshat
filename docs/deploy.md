# VPS 部署清单

本文件描述单用户云 VPS 上的 seshat 服务端部署流程：磁盘加密、构建、密钥注入、
systemd 服务与反向代理，并提供启动验证与部署检查清单。所有命令可直接复制执行。

相关文档：[安全说明](security.md)、[数据备份与恢复](backup.md)、
[配置说明](configuration.md)、[架构设计](architecture.md)。

> **本文只覆盖服务端（`cmd/server`）的单机部署**。客户端（Emacs / Android）与
> 本地 LLM 节点（`cmd/llmnode`）见各自文档；本地节点的构建命令见第 3 节。

## 1. 前置要求

| 项 | 要求 | 说明 |
|---|---|---|
| 操作系统 | 主流 Linux 发行版（Debian/Ubuntu、RHEL 系等） | 需 systemd |
| Go | 1.27 及以上 | 用于编译服务端与本地节点 |
| gcc / CGO | 启用 DB 层加密时必须 | `CGO_ENABLED=1` + `gcc`，SQLCipher 驱动需要 C 编译器 |
| 反向代理 | nginx 或 caddy | 终止 TLS、对外暴露 HTTPS（见第 7 节） |
| 域名 | 指向 VPS 的 A/AAAA 记录 | 用于 Let's Encrypt 签发证书 |
| VPS | 可用的云主机 + 一块可清空的数据盘 | 数据盘用于 LUKS 加密与数据存放 |
| 加密工具 | `cryptsetup`（LUKS） | 第 2 节磁盘加密 |
| 备份工具 | `tar`、`date`、`find`、`awk`；`sqlite3`、`sha256sum` 可选 | 见 [数据备份与恢复](backup.md) |

安装示例（Debian/Ubuntu）：

```bash
sudo apt-get update
sudo apt-get install -y golang build-essential cryptsetup nginx
```

> **无需安装系统 `libsqlcipher`**：加密驱动 `github.com/mutecomm/go-sqlcipher/v4`
> 自带 SQLCipher 源码，编译只需 `gcc` + `CGO_ENABLED=1`。

## 2. 磁盘加密（LUKS，硬性）

### 2.1 为什么必须做

seshat 采用**静态加密**，分磁盘层与数据库层两层（见
[安全说明 · 1. 加密模型](security.md#1-加密模型)）：

- **数据库层**：SQLCipher。仅在以 `-tags sqlcipher` 构建时生效（见第 3 节）。
- **磁盘层**：LUKS 加密承载 `data/`（数据库、笔记目录、附件对象库）与 git 版本库的数据盘。

> **静态加密依赖 LUKS 兜底**：使用默认（非加密）构建时，DB 文件为**明文**，
> 此时磁盘 LUKS 是唯一的静态加密手段。即使 DB 层加密已启用，LUKS 仍作为数据盘
> 兜底，二者叠加。**任何部署都必须对数据盘启用 LUKS。**

### 2.2 创建加密数据盘

以下以整块数据盘 `/dev/sdb` 作为加密容器（**`luksFormat` 会清空该设备，执行前务必确认设备名**）：

```bash
# 1. 在数据盘上创建 LUKS 容器（交互式设置口令）
sudo cryptsetup luksFormat /dev/sdb

# 2. 解锁并映射为 /dev/mapper/seshat-data
sudo cryptsetup luksOpen /dev/sdb seshat-data

# 3. 在解密后的映射设备上创建文件系统
sudo mkfs.ext4 /dev/mapper/seshat-data

# 4. 挂载到数据目录（与 systemd 的工作目录保持一致，见第 6 节）
sudo mkdir -p /srv/seshat/data
sudo mount /dev/mapper/seshat-data /srv/seshat/data
```

### 2.3 验证加密已生效

```bash
# 查看 LUKS 容器状态（应显示 cipher / key size / 状态为 active）
sudo cryptsetup status seshat-data

# 确认数据目录挂载在加密映射设备上
findmnt /srv/seshat/data

# 确认底层块设备的文件系统类型为 crypto_LUKS
sudo blkid /dev/sdb
```

### 2.4 开机自动解锁与挂载

```bash
# 记录 LUKS 容器 UUID（写入 crypttab 用）
sudo cryptsetup luksUUID /dev/sdb

# 注册开机解锁：<name> <UUID> none luks
echo 'seshat-data UUID=<上一步得到的 UUID> none luks' | sudo tee -a /etc/crypttab

# 注册开机挂载
echo '/dev/mapper/seshat-data /srv/seshat/data ext4 defaults 0 2' | sudo tee -a /etc/fstab
```

> **LUKS 口令与头部信息须离线备份**（`cryptsetup luksHeaderBackup`），丢失口令 =
> 数据不可恢复，详见 [安全说明 · 4.1 备份对象](security.md#41-备份对象)。

## 3. 构建

将源码放到部署目录（示例 `/opt/seshat`）：

```bash
git clone <仓库地址> /opt/seshat
cd /opt/seshat
```

### 3.1 加密构建（推荐）

启用 SQLCipher（DB 文件级加密）与 FTS5（全文索引所需）两个 build tag：

```bash
CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" -o seshat-server ./cmd/server
```

本地 LLM 节点 worker（`./cmd/llmnode`，仅用标准库，可选构建）：

```bash
CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" -o seshat-llmnode ./cmd/llmnode
```

> 两个 tag 都不可省略：`sqlcipher` 提供 DB 层加密；`sqlite_fts5` 编入 FTS5 虚表，
> 缺失会在迁移时运行期报 `no such module: fts5`。

### 3.2 非加密回退

不启用 DB 层加密时，使用默认驱动（纯 Go，无 CGO）：

```bash
go build -o seshat-server ./cmd/server
```

> **此构建产出的数据库为明文，机密性完全依赖第 2 节的 LUKS。** 仅在明确接受
> 「数据盘加密兜底」的前提下使用；此时 `SESHAT_DB_KEY` 被忽略（仅记录降级告警）。

## 4. 密钥生成与注入

### 4.1 生成密钥

`scripts/gen-secrets.sh` 生成数据库密钥与访问令牌（文件权限 0600，不回显密钥值）：

```bash
# 生成到部署位置（脚本会自动创建目录并设 600）
sudo scripts/gen-secrets.sh /etc/seshat/secrets.env

# 收紧属主：仅 root 可读、seshat 组可读
sudo chown root:seshat /etc/seshat/secrets.env
sudo chmod 600 /etc/seshat/secrets.env
```

密钥清单（模板见 [`deploy/seshat.env.example`](../deploy/seshat.env.example)）：

| 变量 | 用途 | 来源 |
|---|---|---|
| `SESHAT_DB_KEY` | 存储层数据库密钥（32 字节 hex） | 脚本生成 |
| `SESHAT_AUTH_TOKEN` | REST Bearer + WebDAV Basic 令牌 | 脚本生成 |
| `SESHAT_NODE_TOKEN` | 本地 LLM 节点专用令牌（节点端点，最小权限） | 脚本生成 |
| `SESHAT_LLM_API_KEY` | 云端 LLM API key | 脚本不生成，未启用云端 LLM 时留空 |

脚本默认拒绝覆盖已存在的文件（避免误覆盖密钥），确需重生成时先删除或设 `FORCE=1`。

> **`SESHAT_DB_KEY` 丢失 = 数据永久丢失。** 启用 DB 层加密后，缺少该密钥即使
> 数据盘完好也无法解密。密钥必须**单独、离线**备份，且与数据备份分离存放——
> 仅持有其中一份都不可用。详见 [安全说明 · 4. 备份与恢复演练](security.md#4-备份与恢复演练)。

### 4.2 注入方式

由 systemd 单元通过 `EnvironmentFile` 注入（不由 `config.yaml` 读取）：

- 单元模板：[`deploy/seshat.service.example`](../deploy/seshat.service.example)
  （`EnvironmentFile=/etc/seshat/secrets.env`）。
- 变量模板：[`deploy/seshat.env.example`](../deploy/seshat.env.example)（值为占位符）。

禁止将密钥写入 `config.yaml` 或任何配置文件（同名 YAML 键会被忽略），
禁止提交到 git，详见 [安全说明 · 3.3 注入方式](security.md#33-注入方式)。

## 5. 配置文件

复制示例配置为 `config.yaml`（放在服务工作目录，默认 `/srv/seshat/config.yaml`）：

```bash
sudo cp config.example.yaml /srv/seshat/config.yaml
```

重点配置项（完整说明见 [配置说明](configuration.md) 与
[`config.example.yaml`](../config.example.yaml)）：

| YAML 键 | 默认值 | 说明 |
|---|---|---|
| `server.addr` | `":8080"` | HTTP 监听地址。**生产建议改为 `127.0.0.1:8080`**，仅由反向代理对外 |
| `webdav.root` | `"./data/seshat"` | 笔记根目录（内部 WebDAV `/dav/`），git 工作区 |
| `webdav.public` | `"./data/seshat/public"` | 对外公开出口目录（WebDAV `/public/`） |
| `webdav.public_read_only` | `false` | 为 `true` 时对外出口拒绝一切写操作（PUT/MKCOL/DELETE/MOVE/COPY 等），读操作不受影响 |
| `webdav.public_allow_exts` | `[]` | 对外出口可写入扩展名白名单（如 `[".org", ".md", ".pdf", ".epub"]`），留空不限制 |

> `webdav.root` / `webdav.public` 决定对外暴露范围，`public_read_only` 与
> `public_allow_exts` 共同约束对外写入。公开出口通常是笔记根下的子目录
> （如 `<root>/public`），对外写入也会产生 git commit 并进入 FTS 索引。

## 6. systemd 服务

基于 [`deploy/seshat.service.example`](../deploy/seshat.service.example) 部署：

```bash
# 1. 安装二进制到系统路径
sudo install -m 0755 seshat-server /usr/local/bin/seshat-server

# 2. 安装单元文件
sudo cp deploy/seshat.service.example /etc/systemd/system/seshat.service

# 3. 按本清单路径调整单元文件
sudo sed -i \
  -e 's#^ExecStart=.*#ExecStart=/usr/local/bin/seshat-server#' \
  -e 's#^WorkingDirectory=.*#WorkingDirectory=/srv/seshat#' \
  -e 's#^ReadWritePaths=.*#ReadWritePaths=/srv/seshat#' \
  /etc/systemd/system/seshat.service

# 4. 准备数据目录（挂载点见第 2 节）
sudo install -d -o seshat -g seshat /srv/seshat
```

单元文件的关键点（模板已含）：

- `User=seshat` / `Group=seshat`：专用运行用户，不以 root 运行。
- `EnvironmentFile=/etc/seshat/secrets.env`：注入 `SESHAT_DB_KEY` /
  `SESHAT_AUTH_TOKEN` / `SESHAT_NODE_TOKEN` / `SESHAT_LLM_API_KEY`（权限 600，属主 `root:seshat`）。
- `ExecStart=/usr/local/bin/seshat-server`、`WorkingDirectory=/srv/seshat`。
- `Restart=on-failure` / `RestartSec=5s`：异常退出自动重启。
- 最小权限加固：`NoNewPrivileges=true`、`PrivateTmp=true`、
  `ProtectSystem=strict`、`ProtectHome=true`、`ReadWritePaths=/srv/seshat`。

> **模板路径说明**：仓库模板 [`deploy/seshat.service.example`](../deploy/seshat.service.example)
> 默认写 `ExecStart=/usr/local/bin/seshat-server`、`WorkingDirectory=/srv/seshat`，与本节一致
> （工作目录与 [数据备份与恢复](backup.md) 的 `/srv/seshat/data` 对齐）；上面的 `sed` 用于
> 按部署环境统一对齐这三项，**唯一要求是 `ExecStart` 与实际二进制名一致**。

## 7. 反向代理 HTTPS

服务进程监听 `127.0.0.1:8080`（第 5 节），由反向代理终止 TLS 并对公网暴露 HTTPS
（见 [安全说明 · 5. 传输安全](security.md#5-传输安全)）。三类流量共用同一后端端口：

| 路径 | 用途 | 认证 |
|---|---|---|
| `/api/` | REST API 与 Web UI 静态资源 | `Authorization: Bearer <SESHAT_AUTH_TOKEN>` |
| `/dav/` | 内部 WebDAV（笔记根目录，读写） | Basic，密码为 `SESHAT_AUTH_TOKEN`，用户名任意 |
| `/public/` | 对外 WebDAV（公开出口，按配置只读/白名单） | Basic，同上 |

### 7.1 nginx 示例

```nginx
server {
    listen 443 ssl;
    http2 on;
    server_name seshat.example.com;

    # Let's Encrypt 证书（certbot 自动续期）
    ssl_certificate     /etc/letsencrypt/live/seshat.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/seshat.example.com/privkey.pem;

    # HSTS：服务端**不**下发（TLS 在这里终止，服务端判断不了真实 scheme），由反代负责。
    # `always` 是关键——nginx 的 add_header 默认只作用于 2xx/3xx，加 always 才让
    # 401/4xx/5xx 响应也带上该头。上线前先确认 HTTPS 全站可用（HSTS 会被浏览器记住）。
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    # 大文件上传：放宽请求体上限（按需调整，单位 g）
    client_max_body_size 2g;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;

        # 透传 WebDAV 方法（PUT/DELETE/PROPFIND/MOVE/COPY 等）——
        # nginx proxy 默认透传任意方法，勿添加 limit_except 等限制。
        proxy_set_header Host              $host;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;

        # 传输 HTML/WebDAV 时不做缓冲，避免大文件与 PROPFIND 卡顿
        proxy_request_buffering off;
        proxy_read_timeout      300s;
        proxy_send_timeout      300s;
    }
}

server {
    listen 80;
    server_name seshat.example.com;
    return 301 https://$host$request_uri;
}
```

### 7.2 caddy 示例

```caddyfile
seshat.example.com {
    # Caddy 自动申请并续期 Let's Encrypt 证书
    reverse_proxy 127.0.0.1:8080

    # Caddy **默认不下发** HSTS——需要显式添加。服务端不代发（TLS 在此终止，
    # 服务端看不到真实 scheme，见 docs/security.md §5）。
    header Strict-Transport-Security "max-age=31536000; includeSubDomains"
}
```

> Caddy 的 `header` 指令对全部响应生效（含 4xx/5xx），不需要 nginx 那样的 `always`。

### 7.3 代理要点

- **大文件上传**：调高 `client_max_body_size`，并关闭 `proxy_request_buffering`
  （避免大附件先落盘到代理再转发）。
- **超时**：WebDAV 大文件读写与 LLM 长任务耗时较长，放宽 `proxy_read_timeout` /
  `proxy_send_timeout`（示例 300s）。
- **WebDAV 方法透传**：`/dav/` 与 `/public/` 使用 `PROPFIND`、`PUT`、`DELETE`、
  `MOVE`、`COPY` 等方法；确保代理不限制请求方法（nginx 默认透传，caddy 亦默认透传）。
- **认证透传**：不要把 `Authorization` 头改写或剥离；REST 的 Bearer 与 WebDAV 的
  Basic 都由服务端校验。
- **仅环回暴露**：服务只监听 `127.0.0.1:8080`，明文端口不直接暴露公网。
- **安全响应头分工**：`nosniff` / `X-Frame-Options: DENY` / `Referrer-Policy: no-referrer`
  由**服务端**对全部路由下发（`internal/api/security.go`，见 [安全说明 §5](security.md#5-传输安全)），
  反代不必重复配置；**只有 HSTS 必须在反代设置**——TLS 在此终止，服务端无法判断真实
  scheme。nginx 记得加 `always`（否则 4xx/5xx 不带该头），Caddy 需用 `header` 指令显式添加
  （默认不下发）。

## 8. 启动与验证

```bash
# 重载单元并启用开机自启
sudo systemctl daemon-reload
sudo systemctl enable --now seshat

# 查看状态（应 active (running)，无密钥/解密相关错误）
sudo systemctl status seshat
```

验证端点（以 `https://seshat.example.com` 为例，`$SESHAT_AUTH_TOKEN` 取自
`/etc/seshat/secrets.env`，勿在命令中内联明文值）：

```bash
# 1) 未认证访问 REST：期望 401（缺失令牌被中间件拒绝）
curl -s -o /dev/null -w '%{http_code}\n' \
  https://seshat.example.com/api/progress/health-check

# 2) 认证访问 WebDAV 目录列举：期望 207 Multi-Status
curl -s -o /dev/null -w '%{http_code}\n' \
  -u "user:$SESHAT_AUTH_TOKEN" -X PROPFIND -H 'Depth: 1' \
  https://seshat.example.com/dav/

# 3) 认证访问全文搜索端点：期望 200（返回 JSON）
curl -s -H "Authorization: Bearer $SESHAT_AUTH_TOKEN" \
  'https://seshat.example.com/api/search?q=note&limit=10'
```

重启验证（确认自启与数据可用）：

```bash
# 重启服务
sudo systemctl restart seshat

# 或整机重启后确认服务自动拉起
sudo reboot
# 登录后：
systemctl is-active seshat    # 期望输出 active
```

## 9. 备份衔接

部署完成后立即配置定时备份，并对 `secrets.env` 做离线备份。备份策略、运行方式
（`scripts/backup.sh`）、恢复演练详见 [数据备份与恢复](backup.md)。

要点：

- **数据备份**：`scripts/backup.sh` 打包数据库、笔记目录（含 git）、附件对象库，
  默认保留 7 份，定时任务示例见
  [数据备份与恢复 · 2.2 定时任务示例](backup.md#22-定时任务示例)。
- **密钥备份**：`secrets.env` **不在**数据备份内，须单独离线保管，见
  [安全说明 · 4. 备份与恢复演练](security.md#4-备份与恢复演练)。
- 建议：部署时执行一次完整恢复演练，此后每季度或每次密钥/数据盘变更后复演。

## 10. Docker 部署（替代 systemd）

第 2–9 节描述 systemd 原生部署；本节提供**完全自包含的 Docker 替代方式**：镜像以
加密构建产出（SQLCipher + FTS5），数据与密钥经卷 / 环境变量注入，**不烘焙进镜像**。
两种方式二选一，数据布局与配置文件保持一致（检查清单见第 11 节）。

相关文件：[`Dockerfile`](../Dockerfile)、[`docker-compose.yml`](../docker-compose.yml)、
[`.dockerignore`](../.dockerignore)。

### 10.1 前置要求

Docker（含 Compose v2 插件）已安装：

```bash
docker --version
docker compose version
```

复制并修改配置（容器内工作目录为 `/app`，配置默认路径 `./config.yaml`，数据路径
`./data/...`，与 `config.example.yaml` 默认值一致）：

```bash
cp config.example.yaml config.yaml
```

生成密钥并收紧权限（`scripts/gen-secrets.sh` 默认输出 `./data/secrets.env`，且脚本已
自动设为 600；此处显式 `chmod 600` 以确保权限正确）：

```bash
scripts/gen-secrets.sh data/secrets.env
chmod 600 data/secrets.env
```

> 密钥文件 `data/secrets.env` 经 compose 的 `env_file` 注入（第 10.3 节），内含
> `SESHAT_DB_KEY` / `SESHAT_AUTH_TOKEN` / `SESHAT_NODE_TOKEN` / `SESHAT_LLM_API_KEY`；
> **禁止提交到 git**（第 4.2 节、[安全说明 · 3.3 注入方式](security.md#33-注入方式)）。

### 10.2 构建与启动

```bash
# 构建镜像（多阶段；首次需下载 Go 模块 + CGO 编译，耗时较长）
docker compose build

# 后台启动 seshat 服务
docker compose up -d

# 跟踪日志
docker compose logs -f seshat
```

或一步构建并启动：`docker compose up -d --build`。

常用运维命令：

```bash
docker compose ps        # 查看容器状态
docker compose restart   # 重启
docker compose down      # 停止并移除容器（数据保留在 ./data）
```

### 10.3 卷与环境变量

| 宿主 | 容器 | 说明 |
|---|---|---|
| `./data` | `/app/data` | **数据卷**：`seshat.db`（SQLCipher 库）、笔记目录 `seshat/`、附件对象库 `files/objects/`，以及密钥文件 `secrets.env` |
| `./config.yaml` | `/app/config.yaml`（`:ro`） | **只读**挂载配置文件；容器工作目录 `/app` 与默认配置路径 `./config.yaml` 对齐 |
| `./data/secrets.env` | —（`env_file`） | 注入 `SESHAT_DB_KEY` / `SESHAT_AUTH_TOKEN` / `SESHAT_NODE_TOKEN` / `SESHAT_LLM_API_KEY`，**不进镜像层** |

> 端口映射 `8080:8080`（对应 `server.addr`，第 5 节）。生产环境应改用反向代理终止
> TLS（第 7 节），避免将明文端口直接暴露公网。

### 10.4 镜像说明

- **多阶段构建**：`golang:1.27.1`（构建）→ `debian:trixie-slim`（运行），与本地 Go
  版本（`go.mod` 要求 `go 1.27.1`）一致。
- **加密构建**：`CGO_ENABLED=1` + `-tags "sqlcipher sqlite_fts5"`，与第 3.1 节本地命令
  保持一致；同时产出 `seshat-server` 与 `seshat-llmnode` 两个二进制。
- **非 root 运行**：容器内以 `seshat` 用户（uid/gid 默认 **1000**）运行；Dockerfile
  预建 `/app/data`，`EXPOSE 8080`，`ENTRYPOINT` 为 `seshat-server`。
- **GOPROXY 可覆盖**：构建默认使用 `https://goproxy.cn,direct`（容器内直连
  `proxy.golang.org` 常被网络策略阻断）；如需其它源或内网代理：

  ```bash
  docker build --build-arg GOPROXY=https://goproxy.io,direct -t seshat-server:local .
  ```

- **依赖层缓存**：先 `COPY go.mod go.sum` 并 `go mod download`，仅源码变更时复用缓存。
- **glibc 一致**：runtime 与 builder 同为 Debian 13（trixie）/ glibc 2.41，
  CGO 二进制动态链接无前向不兼容（规避 `GLIBC_x.y not found`）。
- **宿主 uid 不一致时**：若宿主 `./data` 属主 uid 非 1000，带 build-arg 构建：

  ```bash
  docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t seshat-server:local .
  ```

### 10.5 本地 LLM 节点（可选）

本地处理节点（`cmd/llmnode`）通常运行在**家庭机器 / NAS**，而非云服务器，故
`docker-compose.yml` 中的 `llmnode` 服务默认以**注释**形式提供，`docker compose up`
仅启动 `seshat`。若确需同机运行，取消注释并按需配置：

- `SESHAT_SERVER_URL`：**必填**，服务端根地址（如 `https://seshat.example.com`）。
- `SESHAT_NODE_TOKEN`：节点专用令牌；未配置则回退 `SESHAT_AUTH_TOKEN`。
- `OLLAMA_URL` / `OLLAMA_MODEL`：本机 Ollama 地址与模型。Linux 下
  `host.docker.internal` 依赖 `extra_hosts: "host.docker.internal:host-gateway"`；
  不可用时改用宿主 IP 或 `network_mode: host`。
- `NODE_NAME`：节点名，默认取主机名。

镜像内已含 `seshat-llmnode`，该服务通过 `command: ["/usr/local/bin/seshat-llmnode"]`
覆盖默认入口。

### 10.6 systemd 与 Docker 对比

| 维度 | systemd（第 2–9 节） | Docker（本节） |
|---|---|---|
| 隔离性 | 进程级；systemd 加固（`NoNewPrivileges` / `ProtectSystem=strict` / `ProtectHome` / `PrivateTmp` / `ReadWritePaths`） | 容器级；独立命名空间 + 非 root 用户（uid 1000） |
| 部署复杂度 | 需装 Go 工具链、CGO 编译、手写单元文件、安装二进制、配置数据盘挂载 | 装 Docker 后 `docker compose up -d --build` 一条命令 |
| 数据位置 | 本地目录 `/srv/seshat/data`（建议置于 LUKS 加密盘） | 卷 `./data:/app/data`（宿主目录，同样建议置于加密盘） |
| 密钥注入 | systemd `EnvironmentFile=/etc/seshat/secrets.env` | compose `env_file: ./data/secrets.env` |
| 加密构建 | 宿主 `CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5"` | 镜像内多阶段构建，同为 `CGO_ENABLED=1` + 相同 tags |
| 适用场景 | 长期稳定 VPS、精确资源/权限控制、已有 systemd 运维习惯 | 快速部署与迁移、环境一致性、不愿在宿主安装 Go 工具链 |

> 两种方式共用同一份二进制、同一 `config.yaml` 与环境变量，数据布局一致；密钥管理、
> LUKS 兜底与备份要求不变（第 2、4 节与[数据备份与恢复](backup.md)）。

### 10.7 验证

```bash
# 1) 首页（Web UI）：期望 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/

# 2) 未认证访问 REST：期望 401（缺失令牌被中间件拒绝）
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/api/

# 3) 容器状态与日志
docker compose ps
docker compose logs -f seshat
```

确认数据库为 **SQLCipher 密文**（非明文）——SQLCipher 库文件头不再是
`SQLite format 3`：

```bash
# 文件头应为随机字节，而非 "SQLite format 3\x00"
head -c 16 data/seshat.db | xxd

# 或用 file 探测：期望 not a SQLite database
file data/seshat.db
```

> 若 `data/seshat.db` 头部仍为 `SQLite format 3`，说明镜像未启用 `sqlcipher` tag 或未
> 注入 `SESHAT_DB_KEY`，返回第 10.4 / 10.3 节排查。

## 11. 部署检查清单

> 部署方式**二选一**：systemd（第 2–9 节）或 Docker（第 10 节）。带 `[systemd]` /
> `[Docker]` 前缀的条目只需核对所选方式；其余为两种方式通用。

- [ ] VPS 与域名已就绪，域名解析指向本机
- [ ] **LUKS 已启用**：数据盘 `cryptsetup luksFormat` + `luksOpen` + 挂载，
      且 `cryptsetup status` / `findmnt` 验证通过；开机自动解锁已写入 `/etc/crypttab`
      （Docker 方式下 `./data` 所在盘亦须为加密盘）
- [ ] 服务端已构建（加密构建 `-tags "sqlcipher sqlite_fts5"`，或非加密回退 + LUKS 兜底）
- [ ] **密钥已离线备份**：`SESHAT_DB_KEY`（丢失 = 数据永久丢失）与 LUKS 口令/头部
      分离存放于异地离线介质
- [ ] **密钥文件权限 0600**：`[systemd]` `/etc/seshat/secrets.env` 属主 `root:seshat`；
      `[Docker]` `./data/secrets.env`（`scripts/gen-secrets.sh` 生成后 `chmod 600`）
- [ ] `config.yaml` 已就位，`server.addr` 为 `127.0.0.1:8080`，
      `webdav.root`/`public`/`public_read_only`/`public_allow_exts` 符合预期
- [ ] **部署方式已落地（二选一）**：
      `[systemd]` systemd 单元已部署（专用用户 `seshat`、`EnvironmentFile`、
      `ExecStart`、`Restart=on-failure`）；
      `[Docker]` `docker compose build` / `docker compose up -d` 成功、`docker compose ps`
      显示 `seshat` 运行中（`./data`、`./config.yaml` 卷与 `env_file: ./data/secrets.env`
      已就位，容器以非 root uid 1000 运行）
- [ ] **TLS 已配置**：反向代理终止 HTTPS，证书有效期正常，明文端口未暴露公网
- [ ] **反代已下发 HSTS**（服务端不代发：TLS 在反代终止，服务端看不到真实 scheme，见
      [安全说明 §5](security.md#5-传输安全)）：nginx 用 `add_header Strict-Transport-Security
      "max-age=31536000; includeSubDomains" always`（`always` 让 4xx/5xx 也带上），Caddy 用
      `header Strict-Transport-Security …`。`curl -sI https://<域名>/api/roots` 应能看到该头
- [ ] 启动验证通过：`[systemd]` `/api` 未认证返回 401、`PROPFIND /dav/` 返回 207、
      搜索端点返回 200；`[Docker]` `curl /` 返回 200、`/api/` 返回 401
- [ ] **SQLCipher 生效**：`data/seshat.db` 文件头不是 `SQLite format 3`（非明文）
- [ ] **服务自启**：`[systemd]` `systemctl enable` 已执行，重启后
      `systemctl is-active seshat` 为 `active`；`[Docker]` `restart: unless-stopped`
      已配置，重启后容器自动拉起
- [ ] **备份定时任务**已配置（cron 调用 `scripts/backup.sh`），并完成一次恢复演练

## 相关文档

- [安全说明](security.md) — 加密模型、认证、密钥管理、传输安全、恢复演练
- [数据备份与恢复](backup.md) — 备份策略、运行方式、恢复演练
- [配置说明](configuration.md) — 全部配置项与敏感值处理
- [架构设计](architecture.md) — 数据布局与存储层
- [`deploy/seshat.service.example`](../deploy/seshat.service.example) — systemd 单元模板
- [`deploy/seshat.env.example`](../deploy/seshat.env.example) — 环境变量模板
- [`Dockerfile`](../Dockerfile) / [`docker-compose.yml`](../docker-compose.yml) —
  Docker 部署（第 10 节）
- [`scripts/gen-secrets.sh`](../scripts/gen-secrets.sh) / [`scripts/backup.sh`](../scripts/backup.sh)
