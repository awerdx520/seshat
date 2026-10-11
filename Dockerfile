# syntax=docker/dockerfile:1

# =============================================================================
# notes 服务端镜像（多阶段构建）
#
# 构建：  docker build -t notes-server:local .
# 运行：  docker compose up -d --build   （见 docker-compose.yml）
#
# 关键约束：
# - 数据库加密走 SQLCipher（go-sqlcipher 自带 amalgamation），必须 CGO_ENABLED=1
#   且需要 gcc；golang 官方镜像自带 gcc/make 等构建工具，无需额外 apt 安装。
# - 构建标签 sqlcipher（启用加密驱动）与 sqlite_fts5（迁移 v4 的 FTS5 虚表必需），
#   两者都不能省略，与本地构建命令保持一致。
# - 敏感值（NOTES_DB_KEY / NOTES_AUTH_TOKEN / NOTES_NODE_TOKEN / NOTES_LLM_API_KEY）
#   只通过环境变量注入，绝不烘焙进镜像层。
# =============================================================================

# -----------------------------------------------------------------------------
# 阶段 1：构建（Go 版本与本地一致：go1.27.1）
# -----------------------------------------------------------------------------
FROM golang:1.27.1 AS builder

# 模块代理：容器内直连 proxy.golang.org 常被网络策略阻断（本机实测 dial 超时），
# 改用可直连的镜像源；如需其它源或内网代理，构建时覆盖：
#   docker build --build-arg GOPROXY=https://goproxy.io,direct -t notes-server:local .
ARG GOPROXY=https://goproxy.cn,direct
ENV GOPROXY=${GOPROXY}

WORKDIR /src

# 先复制依赖清单并下载模块，使依赖层在仅源码变更时仍可复用缓存。
COPY go.mod go.sum ./
RUN go mod download

# 再复制其余源码；.dockerignore 已排除 android/、emacs/、data/、.git/ 等非必需项。
COPY . .

# 两个二进制统一启用 SQLCipher + FTS5（CGO 必需）。
RUN CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" -o /out/notes-server ./cmd/server \
 && CGO_ENABLED=1 go build -tags "sqlcipher sqlite_fts5" -o /out/notes-llmnode ./cmd/llmnode

# -----------------------------------------------------------------------------
# 阶段 2：运行（精简基础镜像，非 root）
#
# 选用 trixie-slim 而非 bookworm-slim：builder 基础镜像 golang:1.27.1 即 Debian 13
# (trixie) / glibc 2.41（实测），CGO 构建的二进制动态链接 glibc；运行镜像与构建镜像
# 保持同一 glibc 版本可避免「GLIBC_x.y not found」的前向不兼容风险。
# -----------------------------------------------------------------------------
FROM debian:trixie-slim

# 运行用户 uid/gid，默认 1000（多数 Linux 宿主首个普通用户）。
# 若宿主 ./data 属主 uid 不同，构建时覆盖：
#   docker build --build-arg UID=$(id -u) --build-arg GID=$(id -g) -t notes-server:local .
ARG UID=1000
ARG GID=1000

# CA 根证书：出站 HTTPS（云端 LLM API、WebDAV 等）校验需要。
# 不用 apt 安装 ca-certificates（构建环境到 deb.debian.org 极慢），直接复用 builder
# 镜像内已有的证书 bundle；trixie-slim 与 builder 同为 Debian 13。
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt

COPY --from=builder /out/notes-server /usr/local/bin/notes-server
COPY --from=builder /out/notes-llmnode /usr/local/bin/notes-llmnode

# 非 root 运行用户，并预建数据目录（notes.db + notes/ + files/objects/）；
# 由 compose bind mount 覆盖时需保证宿主目录属主 uid 与 ARG UID 一致。
RUN groupadd --gid "${GID}" notes \
 && useradd --uid "${UID}" --gid "${GID}" --no-create-home --shell /usr/sbin/nologin notes \
 && install -d -o notes -g notes /app/data

# 工作目录与配置默认路径 ./config.yaml 对齐（见 cmd/server/main.go defaultConfigPath）。
WORKDIR /app

USER notes

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/notes-server"]
