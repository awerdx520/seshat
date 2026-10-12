# 数据备份与恢复

本文件描述 seshat 服务的备份策略与恢复演练，覆盖数据库、笔记目录、附件对象库
与 git 版本库。密钥（`secrets.env`）的备份是**独立**且强制的流程，见
[安全说明 · 4. 备份与恢复演练](security.md#4-备份与恢复演练)。

相关文档：[安全说明](security.md)、[配置说明](configuration.md)、
[架构设计](architecture.md)。

## 1. 备份策略

### 1.1 备份对象（自动备份）

由 `scripts/backup.sh` 打包，默认路径与位置如下：

| 内容 | 默认路径 | 说明 |
|---|---|---|
| 数据库 | `./data/seshat.db` | SQLite 库文件；sqlite3 可用时用 `.backup` 生成在线一致性快照（已合并 WAL），否则 cp 直拷并连同 `-wal`/`-shm` |
| 笔记目录 | `./data/seshat` | Markdown/Org 笔记；其中的 `.git` 版本库随目录一并打包 |
| 附件对象库 | `./data/files/objects` | 按 SHA256 内容寻址的附件二进制 |
| MANIFEST | （归档内） | 记录备份时间、各源路径、备份方式与恢复提示 |

可用环境变量覆盖默认路径：`DB_PATH`、`SESHAT_DIR`、`OBJECTS_DIR`。

### 1.2 不备份的内容

- **密钥文件**（如 `./data/secrets.env`）：由 `scripts/backup.sh` **有意排除**，
  避免密钥随备份介质迁移/泄露。密钥必须**单独、离线**备份，见
  [安全说明 · 4.1 备份对象](security.md#41-备份对象)。
- **磁盘 LUKS 口令/头部**：离线保管，不属于数据备份范围。
- 服务配置（`/etc/seshat/`）、systemd 单元：属部署工件，另行版本化管理。

> 静态加密下**丢失密钥 = 数据永久丢失**：数据备份与密钥备份应分离存放，
> 仅持有其一都无法完整恢复。

### 1.3 保留策略

- 默认保留最近 **7** 份备份，更旧的自动删除。
- 可用 `BACKUP_KEEP` 覆盖（必须 ≥ 1）。删除按归档文件修改时间倒序执行。

## 2. 运行备份

### 2.1 用法

```bash
# 备份到默认目录 ./backups
./scripts/backup.sh

# 备份到指定目录
./scripts/backup.sh /mnt/backup/seshat

# 自定义保留份数与数据路径
BACKUP_KEEP=14 DB_PATH=/srv/seshat/data/seshat.db \
  SESHAT_DIR=/srv/seshat/data/seshat \
  OBJECTS_DIR=/srv/seshat/data/files/objects \
  ./scripts/backup.sh /mnt/backup/seshat
```

| 环境变量 | 默认值 | 说明 |
|---|---|---|
| `BACKUP_KEEP` | `7` | 保留备份份数（≥1） |
| `DB_PATH` | `./data/seshat.db` | 数据库文件路径 |
| `SESHAT_DIR` | `./data/seshat` | 笔记目录（含 `.git`） |
| `OBJECTS_DIR` | `./data/files/objects` | 附件对象库目录 |

脚本依赖 `tar`、`date`、`find`、`awk`；`sqlite3`、`sha256sum` 为可选增强。

### 2.2 定时任务示例

```bash
# 每天 03:00 备份，日志追加到 /var/log/seshat-backup.log
0 3 * * * cd /opt/seshat && ./scripts/backup.sh /mnt/backup/seshat >> /var/log/seshat-backup.log 2>&1
```

## 3. 备份格式

归档为 **tar.gz**，文件名 `seshat-backup-<UTC 时间戳>.tar.gz`，
例如 `seshat-backup-20250101T030000Z.tar.gz`。归档根下布局：

| 归档内路径 | 对应恢复位置 |
|---|---|
| `seshat.db`（及可能的 `seshat.db-wal`/`seshat.db-shm`） | `<数据目录>/seshat.db` |
| `seshat/` | `<数据目录>/seshat/` |
| `objects/` | `<数据目录>/files/objects/` |
| `MANIFEST` | 仅记录信息，不恢复 |

`MANIFEST` 记录备份时间、主机、各源路径、数据库备份方式，并提示
「密钥需单独离线备份（见 [安全说明 · 4](security.md#4-备份与恢复演练)）」。

查看归档内容与清单：

```bash
tar -tzf backups/seshat-backup-20250101T030000Z.tar.gz
tar -xOzf backups/seshat-backup-20250101T030000Z.tar.gz MANIFEST
```

## 4. 恢复演练

模拟「VPS 数据盘丢失、仅剩离线备份归档与离线密钥」的完整恢复流程。

### 步骤 1 — 备份

```bash
./scripts/backup.sh /mnt/backup/seshat
tar -tzf /mnt/backup/seshat/seshat-backup-*.tar.gz      # 确认内容齐全
sha256sum /mnt/backup/seshat/seshat-backup-*.tar.gz     # 记录校验和
```

同时按 [安全说明 · 4.1](security.md#41-备份对象) 将 `secrets.env` 复制到
离线介质（记录校验和，勿记录密钥值）。

### 步骤 2 — 模拟丢失

在测试实例上删除数据目录与解密挂载，确认服务无法启动 / 数据不可读：

```bash
sudo systemctl stop seshat
sudo rm -rf /srv/seshat/data
# 或在无 LUKS 解密的实例上直接启动，验证数据不可读
```

### 步骤 3 — 恢复数据

```bash
# 解包到临时目录
work="$(mktemp -d)"
tar -xzf /mnt/backup/seshat/seshat-backup-20250101T030000Z.tar.gz -C "$work"

# 还原到数据目录（按第 3 节布局对位）
sudo install -d -o seshat -g seshat /srv/seshat/data/files
sudo install -m 600 "$work/seshat.db" /srv/seshat/data/seshat.db
rm -rf /srv/seshat/data/seshat && sudo cp -a "$work/seshat" /srv/seshat/data/seshat
sudo cp -a "$work/objects" /srv/seshat/data/files/objects
sudo chown -R seshat:seshat /srv/seshat/data
```

> 若归档内含 `seshat.db-wal`/`seshat.db-shm`（cp 直拷模式），需一并还原到
> 数据库文件同目录。

### 步骤 4 — 恢复密钥

密钥**不在数据归档内**，须从离线介质单独还原：

```bash
sudo install -m 600 -o root -g seshat /media/offline/secrets.env /etc/seshat/secrets.env
```

详见 [安全说明 · 3.3 注入方式](security.md#33-注入方式) 与
[4.2 恢复演练步骤](security.md#42-恢复演练步骤)。

### 步骤 5 — 重启服务并验证

```bash
sudo systemctl start seshat
sudo systemctl status seshat
```

验证项：

- 服务正常启动，无密钥/解密相关错误；
- REST API 可用既有令牌访问（`Authorization: Bearer <SESHAT_AUTH_TOKEN>`）；
- 既有笔记可见、git 历史完整（`git -C <数据目录>/seshat log --oneline | head`）；
- 附件可下载，全文索引可查询（如有 FTS5 索引，必要时重建）。

### 步骤 6 — 记录

在 `openspec/completed/` 或运维日志记录：演练日期、备份来源、结果与改进项。
建议频率：部署时执行一次完整演练；此后每季度或每次密钥/数据盘变更后复演。

## 5. 密钥备份

密钥（`SESHAT_DB_KEY`、`SESHAT_AUTH_TOKEN`、`SESHAT_NODE_TOKEN`、`SESHAT_LLM_API_KEY`）**不随数据备份迁移**，
必须单独离线保管：

- 生成：`scripts/gen-secrets.sh`（见 [安全说明 · 3.2 生成](security.md#32-生成)）；
- 备份范围、分离存放原则、轮换流程：见
  [安全说明 · 4. 备份与恢复演练](security.md#4-备份与恢复演练)。

## 6. 相关文档

- [安全说明](security.md) — 加密模型、认证、密钥管理、备份与恢复演练
- [配置说明](configuration.md) — 数据目录与配置项
- [架构设计](architecture.md) — 数据布局与存储层
- `scripts/backup.sh` — 备份脚本
- `scripts/gen-secrets.sh` — 密钥生成脚本
