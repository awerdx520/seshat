#!/usr/bin/env bash
#
# gen-secrets.sh — 生成 notes 服务所需密钥并写入受保护的 env 文件。
#
# 用法：
#     scripts/gen-secrets.sh [输出路径]
#
# 输出路径默认为 ./data/secrets.env，可用第一个参数覆盖。
#
# 行为：
#   - 生成数据库密钥（openssl rand -hex 32）、API 访问令牌与本地 LLM 节点令牌
#     （均 openssl rand -base64 32）；
#   - 写入输出文件，文件权限强制为 600，目标目录不存在时自动创建；
#   - 不向 stdout 回显任何密钥值，仅输出不含值的摘要；
#   - 目标文件已存在时默认拒绝覆盖（静态加密下丢失密钥 = 数据永久丢失），
#     确需重新生成时请先删除文件，或以 FORCE=1 重跑。
#
# 安全：生成的文件属敏感数据，禁止提交到 git，详见 docs/security.md。

set -euo pipefail

out="${1:-./data/secrets.env}"
out_dir="$(dirname -- "$out")"

if [ -e "$out" ] && [ "${FORCE:-0}" != "1" ]; then
    echo "错误：目标文件已存在，拒绝覆盖：$out" >&2
    echo "为避免误覆盖现有密钥（丢失密钥将导致静态加密数据无法恢复），" >&2
    echo "请先确认并删除该文件，或设置 FORCE=1 重跑。" >&2
    exit 1
fi

# 目标目录不存在时创建。
mkdir -p -- "$out_dir"

# 生成密钥；仅在变量/管道中流转，绝不写入 stdout。
db_key="$(openssl rand -hex 32)"
auth_token="$(openssl rand -base64 32)"
node_token="$(openssl rand -base64 32)"

# 以私有 umask 创建文件，再显式收紧权限到 600。
umask 077
{
    printf '# notes 服务密钥文件（由 scripts/gen-secrets.sh 生成）\n'
    printf '# 权限应为 600；仅部署用户可读；禁止提交到 git。\n'
    printf '# 生成时间（UTC）：%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '\n'
    printf '# 数据库密钥（32 字节 hex）：存储层加密使用。\n'
    printf 'NOTES_DB_KEY=%s\n' "$db_key"
    printf '\n'
    printf '# API 访问令牌（单用户）：REST Bearer 与 WebDAV Basic Auth 共用。\n'
    printf 'NOTES_AUTH_TOKEN=%s\n' "$auth_token"
    printf '\n'
    printf '# 本地 LLM 节点专用令牌：仅保护节点端点（注册/轮询/回传，最小权限）；未配置则回退主令牌。\n'
    printf 'NOTES_NODE_TOKEN=%s\n' "$node_token"
    printf '\n'
    printf '# 云端 LLM API key：由用户从服务商获取，脚本不生成；未启用云端 LLM 时留空。\n'
    printf 'NOTES_LLM_API_KEY=\n'
} > "$out"

chmod 600 -- "$out"

# 清空内存中的密钥副本（尽力而为）。
db_key=""
auth_token=""
node_token=""

echo "已生成 3 个密钥并写入 $out（权限 600）：NOTES_DB_KEY、NOTES_AUTH_TOKEN、NOTES_NODE_TOKEN；NOTES_LLM_API_KEY 留空待填写。"
echo "提示：systemd 部署请复制到 /etc/notes/secrets.env 并保持 600 权限；禁止提交到 git。"
