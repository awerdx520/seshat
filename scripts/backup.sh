#!/usr/bin/env bash
#
# backup.sh — seshat 服务数据备份脚本（**不含密钥**）。
#
# 用法：
#     scripts/backup.sh [备份目录]
#
# 备份目录默认为 ./backups，可用第一个参数覆盖。
#
# 备份内容：
#   - 数据库文件（默认 ./data/seshat.db，含 -wal/-shm）：sqlite3 可用时优先用
#     `.backup` 生成在线一致性快照（已合并 WAL），否则退化为 cp 直拷
#     （连同 -wal/-shm 一起拷）。
#   - 笔记目录（默认 ./data/seshat）：其中包含的 .git 版本库随目录一并打包。
#   - 附件对象库（默认 ./data/files/objects）。
#   - MANIFEST：记录备份时间、各路径、备份方式与恢复提示。
#
# 备份格式：tar.gz，文件名 seshat-backup-<UTC 时间戳>.tar.gz。
#
# 保留策略：默认保留最近 7 份，更旧的自动删除；BACKUP_KEEP 可覆盖（>=1）。
#
# 安全：本脚本**不备份密钥文件**（如 ./data/secrets.env）。静态加密下
#       丢失密钥 = 数据永久不可恢复，密钥必须单独、离线备份。
#       详见 docs/security.md「4. 备份与恢复演练」与 docs/backup.md。
#
# 可配置环境变量：
#   BACKUP_KEEP   保留份数（默认 7）
#   DB_PATH       数据库文件路径（默认 ./data/seshat.db）
#   SESHAT_DIR    笔记目录（默认 ./data/seshat）
#   OBJECTS_DIR   附件对象库目录（默认 ./data/files/objects）

set -euo pipefail

backup_root="${1:-./backups}"
keep="${BACKUP_KEEP:-7}"
db_path="${DB_PATH:-./data/seshat.db}"
seshat_dir="${SESHAT_DIR:-./data/seshat}"
objects_dir="${OBJECTS_DIR:-./data/files/objects}"

# —— 校验保留份数 ——
case "$keep" in
    '' | *[!0-9]*)
        echo "错误：BACKUP_KEEP 必须是非负整数，当前为：$keep" >&2
        exit 2
        ;;
esac
if [ "$keep" -lt 1 ]; then
    echo "错误：BACKUP_KEEP 至少为 1（否则会连带删除刚生成的备份）。" >&2
    exit 2
fi

# —— 依赖检查 ——
for tool in tar date find awk; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "错误：缺少依赖命令 $tool" >&2
        exit 3
    fi
done

# —— 至少有一个数据源存在 ——
if [ ! -f "$db_path" ] && [ ! -d "$seshat_dir" ] && [ ! -d "$objects_dir" ]; then
    echo "错误：未找到任何数据源（$db_path / $seshat_dir / $objects_dir）。" >&2
    echo "请确认在数据目录下运行，或用 DB_PATH/SESHAT_DIR/OBJECTS_DIR 覆盖路径。" >&2
    exit 1
fi

mkdir -p -- "$backup_root"
backup_root="$(cd -- "$backup_root" && pwd)"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
out="$backup_root/seshat-backup-$ts.tar.gz"

# 暂存目录：只放数据库快照与 MANIFEST；笔记/附件直接从源打包，
# 避免整份镜像导致的磁盘双倍占用。
stage="$(mktemp -d "${TMPDIR:-/tmp}/seshat-backup.XXXXXX")"
trap 'rm -rf -- "$stage"' EXIT
mkdir -p -- "$stage/db"

# —— 数据库：优先在线一致性快照，否则 cp 直拷 ——
db_files=()
db_how="（数据库不存在，已跳过）"
if [ -f "$db_path" ]; then
    db_base="$(basename -- "$db_path")"
    if command -v sqlite3 >/dev/null 2>&1 \
        && sqlite3 "$db_path" ".backup '$stage/db/$db_base'" >/dev/null 2>&1; then
        db_how="sqlite3 .backup 在线一致性快照（已合并 WAL）"
    else
        cp -p -- "$db_path" "$stage/db/$db_base"
        for suffix in -wal -shm; do
            if [ -f "$db_path$suffix" ]; then
                cp -p -- "$db_path$suffix" "$stage/db/$db_base$suffix"
            fi
        done
        db_how="cp 直拷（含 -wal/-shm）"
    fi
    for f in "$stage/db"/*; do
        [ -e "$f" ] || continue
        db_files+=("$(basename -- "$f")")
    done
fi

# —— 源路径绝对化（仅用于 MANIFEST 记录） ——
src_abs() {
    if command -v realpath >/dev/null 2>&1; then
        realpath -- "$1" 2>/dev/null || printf '%s' "$1"
    else
        printf '%s' "$1"
    fi
}

# —— 写 MANIFEST ——
manifest="$stage/MANIFEST"
{
    printf 'seshat 数据备份 MANIFEST\n'
    printf '========================\n'
    printf '备份时间（UTC）: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '备份主机: %s\n' "$(uname -n 2>/dev/null || echo unknown)"
    printf '备份工具: scripts/backup.sh\n'
    printf '运行目录: %s\n' "$(pwd)"
    printf '保留策略: 最近 %s 份\n' "$keep"
    printf '\n'
    printf '内含内容（tar 根下路径）:\n'
    printf '  MANIFEST                     本文件\n'
    if [ -f "$db_path" ]; then
        printf '  %-28s <- 源: %s（%s）\n' "$(basename -- "$db_path")" "$(src_abs "$db_path")" "$db_how"
    fi
    if [ -d "$seshat_dir" ]; then
        printf '  %-28s <- 源: %s（笔记目录，含其中 .git 版本库）\n' "$(basename -- "$seshat_dir")/" "$(src_abs "$seshat_dir")"
    fi
    if [ -d "$objects_dir" ]; then
        printf '  %-28s <- 源: %s（附件对象库）\n' "$(basename -- "$objects_dir")/" "$(src_abs "$objects_dir")"
    fi
    printf '\n'
    printf '未包含（有意排除）:\n'
    printf '  密钥文件（如 secrets.env）不在自动备份范围内 —— 避免密钥随备份迁移/泄露。\n'
    printf '  密钥需单独离线备份；静态加密下缺失密钥将导致数据永久不可恢复。\n'
    printf '  详见 docs/security.md「4. 备份与恢复演练」与 docs/backup.md。\n'
    printf '\n'
    printf '恢复提示:\n'
    printf '  解包后：%s -> <数据目录>/seshat.db；%s/ -> <数据目录>/seshat/；\n' \
        "$(basename -- "$db_path")" "$(basename -- "$seshat_dir")"
    printf '  %s/ -> <数据目录>/files/objects/。详见 docs/backup.md。\n' "$(basename -- "$objects_dir")"
} > "$manifest"

# —— 打包（多 -C 组合，tar 内保持各条目名清晰） ——
tar_args=(-czf "$out" -C "$stage" MANIFEST)
if [ "${#db_files[@]}" -gt 0 ]; then
    tar_args+=(-C "$stage/db" "${db_files[@]}")
fi
if [ -d "$seshat_dir" ]; then
    tar_args+=(-C "$(dirname -- "$seshat_dir")" "$(basename -- "$seshat_dir")")
fi
if [ -d "$objects_dir" ]; then
    tar_args+=(-C "$(dirname -- "$objects_dir")" "$(basename -- "$objects_dir")")
fi
tar "${tar_args[@]}"

# —— 完整性校验 ——
if ! tar -tzf "$out" >/dev/null 2>&1; then
    echo "错误：备份归档校验失败，已删除：$out" >&2
    rm -f -- "$out"
    exit 4
fi

size="$(du -h -- "$out" | cut -f1)"
echo "备份完成：$out（$size，保留最近 $keep 份）"
if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$out"
fi

# —— 保留策略：按修改时间倒序，删除第 keep 份之后的旧备份 ——
# 说明：依赖 GNU find 的 -printf（VPS 为 Linux）。备份文件名无空格。
while IFS= read -r old; do
    rm -f -- "$old"
    echo "已删除旧备份：$old"
done < <(
    find "$backup_root" -maxdepth 1 -type f -name 'seshat-backup-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn \
        | awk -v k="$keep" 'NR > k { sub(/^[^ ]+ /, ""); print }'
)
