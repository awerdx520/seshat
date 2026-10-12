# Seshat 数据迁移手册（VPS + Emacs + Android）

> 本手册是「`notes` → `Seshat` 全仓改名」计划的**批次 6**产物，供用户在 VPS 与客户端上**手工执行**。
> 本手册**只描述操作**，不自动执行任何迁移；命令中的域名、IP、路径均为占位符（如 `<你的域名>`、`<部署根目录>`、`<数据目录>`），执行前请按第 0 步核对结果替换。
> 全程**不得读取、回显、写入任何真实密钥值**；所有令牌位置一律用占位符并注明「从 VPS 的 `secrets.env` 读取」。
>
> 相关文件：[`deploy/seshat.service.example`](../deploy/seshat.service.example)、[`deploy/seshat.env.example`](../deploy/seshat.env.example)、[`config.example.yaml`](../config.example.yaml)、[`scripts/backup.sh`](../scripts/backup.sh)、[`scripts/gen-secrets.sh`](../scripts/gen-secrets.sh)。
> 参考文档：[VPS 部署](deploy.md)、[数据备份与恢复](backup.md)、[安全说明](security.md)。

## 1. 目的与适用范围

本次迁移把品牌与运行环境从 `notes` 改为 `Seshat`，覆盖三个命名域：

- **A 域（品牌标识）**：Go module/import、Elisp 包名与文件名、Android 源码包名与 App 显示名、二进制/镜像名、systemd unit 名、文档标题。
- **B 域（运行时契约）**：`NOTES_*` → `SESHAT_*` 环境变量、systemd unit 名、compose service / container 名、运行用户/组名。
- **C 域（数据契约）**：服务端数据目录与文件名、WebDAV 远端目录、客户端本地目录、客户端状态文件。

**影响面摘要（一句话）**：服务端的数据文件与配置路径、systemd unit 与运行用户/组全部改名，Emacs 与 Android 客户端的连接配置、远端目录、本地数据目录同步改名；旧数据以**复制**方式保留，作为观察期内的回滚点。

**预计停机时间**：约 **30–60 分钟**（估算）。停机窗口覆盖第 2–7 步（停机 → 改名 → 启动验证）；第 0 步核对与第 1 步备份可在停机窗口外先行完成。实际时长取决于数据规模、备份与磁盘解密（LUKS）耗时。

**适用范围**：单用户自托管 VPS（systemd 原生部署，或 Docker 部署，二选一）及其 Emacs / Android 客户端。本手册不改变任何应用逻辑，只做命名与数据位置的迁移。

**执行顺序总原则**：第 3–5 步都必须在**停机窗口内**完成，且它们操作的路径必须与第 4 步写入 `config.yaml` 的路径、第 5 步写入 unit 的路径**保持一致**。请先完成第 0 步核对并填表，再按记录的实际值替换本手册中的占位符。

## 2. 第 0 步 · 前置核对（硬前置，必须先做）

> ⚠️ **禁止按默认值推断**。服务端 `webdav.root` 与客户端 `remote-dir` 是**两层独立命名**，且 Emacs 默认 `"notes"` 与 Android 默认 `"/"` 本就不一致，说明实际部署已自定义。

### 2.1 两层嵌套警告

WebDAV 客户端看到的文件路径，等于「服务端 root」叠加「客户端 remote-dir」：

```
实际远端路径 = <webdav.root 实际值> / <客户端 remote-dir 实际值> / …
```

举例（仅为说明，非默认值）：

- 若服务端 `webdav.root` 实际为 `./data/notes`，客户端 `remote-dir` 实际为 `notes`，则文件实际位于 `./data/notes/notes/…`；两层同时改名后变为 `./data/seshat/seshat/…`。
- 若客户端 `remote-dir` 实际为 `/`（Android 常见默认），文件直接位于 root 下，**不存在第二层**，改名时不应多移一层目录。
- 若客户端 `remote-dir` 已是自定义值（既非 `notes` 也非 `/`），按其实际值决定是否需要多移一层目录。

因此：**必须先核对，再决定目录改名是否需要多移一层**。

### 2.2 VPS 端核对

```bash
# 1) 核对真实 config.yaml 的三个路径键（config.yaml 不含密钥，可安全查看）
cd <部署根目录>
grep -nE '^[[:space:]]*(path|root|public):' config.yaml

# 2) 核对数据目录实际层级
ls -la <数据目录>
ls -la <数据目录>/<笔记根目录名>

# 3) 核对 data/ 下的实际布局（DB 文件、笔记根、附件对象库）
ls -la <数据目录>/
ls -la <数据目录>/files/
```

核对要点：

- `db.path`、`webdav.root`、`webdav.public` 的**实际值**（可能已自定义，未必是 `./data/notes*`）。
- 笔记根目录内是否包含 `.git/`（版本库随笔记根一起移动）。
- `<数据目录>` 下是否存在 `-wal` / `-shm` 文件（SQLite WAL 模式）。
- 附件对象库的实际位置（默认 `<数据目录>/files/objects`）。
- 运行服务的系统用户名/组名（默认 `notes:notes`）。
- 当前 systemd unit 名（默认 `notes.service`）。
- 若使用 LUKS：解密映射名（默认 `notes-data`）与挂载点。

### 2.3 Emacs 端核对

在 Emacs 中对以下变量执行 `C-h v`（或 `M-x describe-variable`），记录**实际生效值**：

- `seshat-sync-remote-dir`（远端目录，决定 2.1 的第二层）
- `seshat-sync-local-dir`（本地笔记目录）
- `seshat-sync-username`（WebDAV 用户名，服务端忽略，仅本地默认值）
- `seshat-conflict-local-head-file`（HEAD 状态文件）

> 变量名已是 `seshat-*`（Elisp 侧改名已完成）。若你的 `init.el` 里仍用旧符号 `notes-sync-*` 设置这些变量，请同时把符号名改为 `seshat-sync-*`，否则设置不会生效。

### 2.4 Android 端核对

打开 App 的设置页，记录：

- 服务端地址（值不变）
- 远端目录的**实际值**（决定 2.1 的第二层）
- WebDAV 用户名（服务端忽略，仅本地默认值）

### 2.5 核对结果记录表（留空，执行时填写）

| # | 核对项 | 核对命令/位置 | 实际值 | 备注 |
|---|---|---|---|---|
| 1 | 服务端 `webdav.root` | `grep` config.yaml | | C 域，笔记根 |
| 2 | 服务端 `webdav.public` | `grep` config.yaml | | C 域，public 子树 |
| 3 | 服务端 `db.path` | `grep` config.yaml | | C 域，DB 文件 |
| 4 | 数据目录实际路径 | `ls -la` | | |
| 5 | data/ 下布局（DB/笔记根/files） | `ls -la` | | |
| 6 | 笔记根是否含 `.git/` | `ls -la <笔记根>` | | |
| 7 | 运行用户/组 | `systemctl show -p User -p Group <unit>` | | 默认 `notes:notes` |
| 8 | 当前 systemd unit 名 | `systemctl list-units '*.service'` | | 默认 `notes.service` |
| 9 | LUKS 映射名（若用） | `cryptsetup status <映射名>` | | 默认 `notes-data` |
| 10 | Emacs `seshat-sync-remote-dir` | `C-h v` | | 决定第二层 |
| 11 | Emacs `seshat-sync-local-dir` | `C-h v` | | 本地数据 |
| 12 | Emacs `seshat-sync-username` | `C-h v` | | 服务端忽略 |
| 13 | Emacs `seshat-conflict-local-head-file` | `C-h v` | | 状态文件 |
| 14 | Android 远端目录 | App 设置 | | 决定第二层 |
| 15 | 两层叠加后的**实际远端路径** | 综合 1 + 10/14 | | 决定是否多移一层 |

## 3. 第 1 步 · 备份

在**停机前**完成，产出一份完整、可校验的数据备份（备份脚本会排除密钥文件，密钥另行离线备份）。

```bash
cd <部署根目录>
sudo DB_PATH=./data/notes.db SESHAT_DIR=./data/notes ./scripts/backup.sh <备份目录>
```

> ⚠️ **必须显式指向旧路径，不能裸跑脚本**：`scripts/backup.sh` 的默认值已在改名后更新为**新名**（`DB_PATH` 默认 `./data/seshat.db`、`SESHAT_DIR` 默认 `./data/seshat`），而本步在**改名之前**执行，数据此时仍是**旧名**（`./data/notes.db` / `./data/notes`）。若不带上述环境变量直接运行脚本，其「至少一个数据源存在」检查会因附件对象库 `./data/files/objects`（未改名、仍存在）而**静默通过**，但数据库与笔记目录会因默认路径不存在而**被脚本跳过**，最终生成一份**看似成功、实际缺少 DB 与笔记目录**的不完整归档。因此迁移前备份**必须**用 `DB_PATH` / `SESHAT_DIR` 指向旧路径；若你的 VPS 上附件对象库路径也非默认，再按脚本用法追加 `OBJECTS_DIR=<旧对象库路径>`。

- 归档文件名为 `seshat-backup-<UTC 时间戳>.tar.gz`（默认保留最近 7 份）。
- 实际打包的是脚本环境变量指向的三个数据源：数据库（`$DB_PATH`，此处 `./data/notes.db`）、笔记目录（`$SESHAT_DIR`，此处 `./data/notes`，含其中 `.git`）、附件对象库（`$OBJECTS_DIR`，默认 `./data/files/objects`）。

校验归档可读，并与迁移前源文件条数比对：

```bash
# 归档条目总数
tar -tzf <备份目录>/seshat-backup-<UTC 时间戳>.tar.gz | wc -l

# 迁移前源文件条数（仅计数，不读取内容）
find <数据目录>/notes -type f | wc -l
find <数据目录>/files/objects -type f | wc -l

# 归档内两类条目条数（应分别与上面的源条数一致）
# 注：归档内的条目名前缀 = 被备份目录的 basename；此处笔记目录为旧名 ./data/notes，故前缀为 notes/
tar -tzf <备份目录>/seshat-backup-<UTC 时间戳>.tar.gz | grep -c '^notes/'
tar -tzf <备份目录>/seshat-backup-<UTC 时间戳>.tar.gz | grep -c '^objects/'

# 记录归档校验和
sha256sum <备份目录>/seshat-backup-<UTC 时间戳>.tar.gz
```

> **密钥不在备份内**：`secrets.env`（`/etc/seshat/secrets.env`）必须**单独、离线**备份，且与数据备份分离存放；静态加密下丢失密钥 = 数据永久不可恢复。详见 [安全说明 · 4](security.md)。

## 4. 第 2 步 · 停机

停服前 systemd unit 仍是**旧名**（第 0 步核对结果，默认 `notes.service`），因此用旧名停止：

```bash
# 旧 unit 名（第 0 步记录；默认 notes）
sudo systemctl stop notes
sudo systemctl is-active notes     # 期望输出 inactive / failed
```

> 若第 0 步记录的 unit 名不是 `notes`，替换为实际旧名。
> Docker 部署改为：`docker compose stop seshat`（若旧 compose service 名为 `notes`，则用旧名停止）。
> 改名完成后（第 5 步）服务将以新名 `seshat.service` 管理，即 `systemctl start/stop seshat`。

服务停止后，数据库与笔记目录处于静态一致状态，方可在第 3 步安全复制。

## 5. 第 3 步 · 数据改名（`cp -a` 复制，不用 `mv`）

> 用 `cp -a` 而非 `mv`：旧文件/目录**保留**至观察期结束，作为事实上的回滚点（见第 8 步）。

以下 `<数据目录>` 为第 0 步记录的当前数据目录；`<笔记根目录名>` 为 `webdav.root` 的实际末级目录名。

| 项目 | 复制前（旧） | 复制后（新） | 说明 |
|---|---|---|---|
| 笔记根目录 | `<数据目录>/notes` | `<数据目录>/seshat` | `cp -a`；含其中 `.git/` |
| DB 文件 | `<数据目录>/notes.db` | `<数据目录>/seshat.db` | `cp -a`；停服后复制 |
| DB WAL/SHM（若存在） | `<数据目录>/notes.db-wal` / `-shm` | `<数据目录>/seshat.db-wal` / `-shm` | 与 DB 一起复制 |
| public 子树 | `<数据目录>/notes/public` | `<数据目录>/seshat/public` | **是笔记根的子目录，随根一起复制**，无需单独 `cp` |
| 配置文件 | `config.yaml` | `config.yaml.pre-migration` | 回滚用副本（内容修改见第 4 步） |

```bash
cd <部署根目录>

# 1) 笔记根（连同其中 .git 与 public 子树一起复制）
sudo cp -a <数据目录>/notes <数据目录>/seshat

# 2) DB 文件（含 WAL/SHM，若存在）
sudo cp -a <数据目录>/notes.db <数据目录>/seshat.db
[ -f <数据目录>/notes.db-wal ] && sudo cp -a <数据目录>/notes.db-wal <数据目录>/seshat.db-wal
[ -f <数据目录>/notes.db-shm ] && sudo cp -a <数据目录>/notes.db-shm <数据目录>/seshat.db-shm

# 3) 配置文件回滚副本
sudo cp -a config.yaml config.yaml.pre-migration
```

核对复制结果：

```bash
ls -la <数据目录>/
diff -rq <数据目录>/notes <数据目录>/seshat    # 期望无差异输出
```

> **两层嵌套**：若第 0 步核对显示客户端 `remote-dir` 还有一层（见 2.1），请确认复制后的目录层级与客户端将要设置的新值一致；若需要「多移一层」或「少一层」，在此步骤补齐（例如把 `<数据目录>/notes/notes` 复制为 `<数据目录>/seshat/seshat`，或反之）。
>
> **部署根目录改名**：若部署根目录本身名为 `notes`（如 `/srv/notes`、`/opt/notes`），其改名属第 5 步（工作目录调整）范围，此处不要先行 `mv`。

## 6. 第 4 步 · 配置改名

### 6.1 `config.yaml` 三个路径键

| YAML 键 | 旧值（默认） | 新值（默认） |
|---|---|---|
| `db.path` | `./data/notes.db` | `./data/seshat.db` |
| `webdav.root` | `./data/notes` | `./data/seshat` |
| `webdav.public` | `./data/notes/public` | `./data/seshat/public` |

> 按第 0 步记录的**实际值**替换：若实际值已自定义（不是默认），保持其目录层级不变，只把品牌段 `notes` → `seshat`。

```bash
# 先预览（dry-run，不落盘）
grep -nE '^[[:space:]]*(path|root|public):' config.yaml

# 确认后再改（示例：按默认值替换；自定义值请手工对齐）
sudo sed -i 's#\./data/notes\.db#./data/seshat.db#' config.yaml
sudo sed -i 's#\./data/notes\b#./data/seshat#' config.yaml
```

### 6.2 `secrets.env` 的变量名（`NOTES_*` → `SESHAT_*`）

**只处理变量名，任何情况下都不打印、不写入变量值。**

| # | 旧变量名 | 新变量名 | 位置 |
|---|---|---|---|
| 1 | `NOTES_DB_KEY` | `SESHAT_DB_KEY` | `/etc/seshat/secrets.env` |
| 2 | `NOTES_AUTH_TOKEN` | `SESHAT_AUTH_TOKEN` | `/etc/seshat/secrets.env` |
| 3 | `NOTES_NODE_TOKEN` | `SESHAT_NODE_TOKEN` | `/etc/seshat/secrets.env` |
| 4 | `NOTES_LLM_API_KEY` | `SESHAT_LLM_API_KEY` | `/etc/seshat/secrets.env` |
| 5 | `NOTES_SERVER_URL` | `SESHAT_SERVER_URL` | 本地 LLM 节点单元 / compose 环境（**非** secrets.env） |
| 6 | `NOTES_LOG_LEVEL` | `SESHAT_LOG_LEVEL` | 服务端单元 / compose 环境（**非** secrets.env） |

> `secrets.env` 内实际保存 4 个变量（上表 1–4）；上表 5–6 属运行时环境变量，位于对应进程的启动配置中，一并改名（本次改名共涉及 6 个 `NOTES_*` 变量名）。

```bash
# 若配置目录当前为 /etc/notes，先改名目录
sudo mv /etc/notes /etc/seshat

# dry-run：只列变量名（等号前），不显示任何值
sudo cut -d= -f1 /etc/seshat/secrets.env | grep -n '^NOTES_'

# 备份后执行替换（只改行首前缀；不打印文件内容）
sudo cp -a /etc/seshat/secrets.env /etc/seshat/secrets.env.pre-migration
sudo sed -i 's/^NOTES_/SESHAT_/' /etc/seshat/secrets.env

# 复核变量名（仍只显示键名）
sudo cut -d= -f1 /etc/seshat/secrets.env | grep -n '^SESHAT_'
```

> ⚠️ 禁止用会回显整行的方式查看 `secrets.env`（如直接 `cat` / 全文 `grep`），以免把密钥值带入终端回滚缓冲与日志。

## 7. 第 5 步 · 服务名与系统用户改名（D2=乙）

> 系统用户/组改名期间**必须先停服务**（第 2 步已停）。本步在一个连续的停机窗口内完成；任一步失败即按 7.5 回滚。

### 7.1 改名系统用户与组

```bash
# 1) 确认服务已停止、无残留进程（否则 usermod 会失败）
sudo systemctl stop notes 2>/dev/null || true
pgrep -u notes -a || echo "无 notes 用户进程"

# 2) 改组名 → 改用户名（默认 home 为 /srv/notes，按第 0 步实际值替换）
sudo groupmod -n seshat notes
sudo usermod -l seshat -d /srv/seshat -m notes
```

> `usermod -l` 改登录名，`-d` 指定新家目录、`-m` 迁移家目录内容。若该用户家目录与数据目录重合、或部署无需家目录，按实际情况调整（例如省略 `-d` / `-m`）。

### 7.2 调整数据目录与配置目录属主

```bash
sudo chown -R seshat:seshat <数据目录>
sudo chown -R seshat:seshat <配置目录>
```

> `<配置目录>` 即 `/etc/seshat`；密钥文件应保持属主 `root:seshat` 且权限 `600`：
> `sudo chown root:seshat /etc/seshat/secrets.env && sudo chmod 600 /etc/seshat/secrets.env`。

### 7.3 unit 文件改名与内容同步

```bash
# 1) unit 文件改名
sudo mv /etc/systemd/system/notes.service /etc/systemd/system/seshat.service

# 2) 同步 unit 内用户与路径（按第 0 步实际值替换占位符）
sudo sed -i \
  -e 's#^User=.*#User=seshat#' \
  -e 's#^Group=.*#Group=seshat#' \
  -e 's#^WorkingDirectory=.*#WorkingDirectory=/srv/seshat#' \
  -e 's#^EnvironmentFile=.*#EnvironmentFile=<配置目录>/secrets.env#' \
  -e 's#^ReadWritePaths=.*#ReadWritePaths=/srv/seshat#' \
  -e 's#^ExecStart=.*#ExecStart=<安装前缀>/seshat-server#' \
  -e 's#^Description=.*#Description=Seshat 个人笔记同步服务#' \
  /etc/systemd/system/seshat.service
```

unit 目标形态（占位符按实际替换；仓库模板见 `deploy/seshat.service.example`）：

```
[Unit]
Description=Seshat 个人笔记同步服务
Documentation=file:<部署根目录>/README.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=seshat
Group=seshat
WorkingDirectory=/srv/seshat
EnvironmentFile=<配置目录>/secrets.env
ExecStart=<安装前缀>/seshat-server
Restart=on-failure
RestartSec=5s
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/srv/seshat

[Install]
WantedBy=multi-user.target
```

关键约束：

- `ExecStart` 必须指向实际二进制名 `seshat-server`（**无子命令**），与仓库模板一致。
- `EnvironmentFile` 指向密钥文件 `/etc/seshat/secrets.env`。
- `WorkingDirectory` / `ReadWritePaths` 与第 4 步 `config.yaml` 中相对路径的基准一致。

```bash
# 3) 重载 systemd 并启用
sudo systemctl daemon-reload
sudo systemctl enable seshat
```

### 7.4 其他环境项（按实际部署核对）

- **部署根目录改名**：若 `/srv/notes` 或 `/opt/notes` 需改为 `/srv/seshat`、`/opt/seshat`，在本步一并 `mv`，并同步 `WorkingDirectory` 所在路径与 cron / 备份任务的 `cd` 目录。
- **LUKS 映射名（若使用）**：若加密映射名为 `notes-data`，需 `umount` → `cryptsetup luksClose notes-data` → `cryptsetup luksOpen <设备> seshat-data` → 同步 `/etc/crypttab` 与 `/etc/fstab` 中的名称。此操作影响挂载，务必先备份 LUKS 头部并在维护窗口内执行。
- **cron / 定时备份**：更新调用 `scripts/backup.sh` 的定时任务中的目录与日志文件名（`notes-backup.log` → `seshat-backup.log`）。
- **反向代理**：若配置中含品牌字样（如 `server_name`），同步改为新域名。

### 7.5 失败即回滚（改回 `notes`）

若 7.1–7.4 任一步失败、或服务无法启动，按以下步骤回滚用户/组与 unit：

```bash
sudo systemctl stop seshat 2>/dev/null || true

# 改回用户名与组名
sudo groupmod -n notes seshat
sudo usermod -l notes -d /srv/notes -m seshat

# 属主改回
sudo chown -R notes:notes <数据目录>

# unit 文件改回旧名
sudo mv /etc/systemd/system/seshat.service /etc/systemd/system/notes.service
sudo systemctl daemon-reload
sudo systemctl start notes
```

> 回滚后服务应恢复到迁移前的正常状态；数据文件此时仍为第 3 步复制出的新名，若第 4 步的配置改动已写入，需按第 8 步把 `config.yaml` 指回旧路径。

## 8. 第 6 步 · 客户端迁移

### 8.1 Emacs 端

**4 个自定义变量**的旧值 → 新值（变量名已是 `seshat-*`；旧值以第 0 步核对结果为准）：

| 变量 | 旧值 | 新值 |
|---|---|---|
| `seshat-sync-remote-dir` | `"notes"`（或实际值） | `"seshat"`（须与第 0 步两层叠加结果一致） |
| `seshat-sync-local-dir` | `"~/notes"` | `"~/seshat"` |
| `seshat-sync-username` | `"notes"` | `"seshat"` |
| `seshat-conflict-local-head-file` | `"~/.emacs.d/notes-head"` | `"~/.emacs.d/seshat-head"` |

> `seshat-sync-server-url` 与 `seshat-sync-token` 的**值不变**（仅变量名前缀随 Elisp 侧改名，值沿用迁移前配置）。
> 若 `init.el` 中仍以旧符号 `notes-sync-*` 设置，请同步改符号名为 `seshat-sync-*`。

本地数据目录与状态文件改名（用 `mv`）：

```bash
mv ~/notes ~/seshat
mv ~/.emacs.d/notes-head ~/.emacs.d/seshat-head
```

### 8.2 Android 端（D1/D3=乙）

新包名 `com.seshat.app` 等同于**全新 App**，需卸载旧版并重装：

```bash
# 1) 卸载旧 App（旧包名）
adb uninstall com.notes.app

# 2) 安装新 APK（新包名 com.seshat.app）
adb install <新 APK 路径>/seshat-release.apk
```

安装后在 App 设置页重新输入：

- **服务端地址**：与迁移前一致（值不变）。
- **WebDAV 用户名**：`seshat`（服务端忽略用户名）。
- **远端目录**：按第 0 步核对结果设置（默认 `seshat`）。
- **访问令牌**：从 VPS 的 `secrets.env`（变量 `SESHAT_AUTH_TOKEN`）现场读取。

> ⚠️ **令牌处理红线**：令牌只能从 VPS 的 `/etc/seshat/secrets.env` 现场读取并粘贴到 App，**不得截图、不得写入任何文件、不得出现在本文档、日志或命令历史中**。粘贴后建议清理 shell 历史。

**Web 管理界面（浏览器）**：管理界面在浏览器 `localStorage` 中用 `notes.token` 保存 API 令牌；本次改名为 `seshat.token`。升级后打开管理界面需**重新粘贴一次 API 令牌**（令牌从 VPS 的 `secrets.env` 读取，请勿写入任何文件或截图）。

## 9. 第 7 步 · 启动与验证

### 9.1 启动服务

```bash
sudo systemctl start seshat
systemctl is-active seshat        # 期望 active
sudo systemctl status seshat      # 期望 active (running)，无密钥/解密相关错误
```

### 9.2 健康检查（用变量引用，不内联明文令牌）

```bash
# 从密钥文件载入变量（不打印任何值）
set -a; . /etc/seshat/secrets.env; set +a

# 1) 未认证访问 REST：期望 401
curl -s -o /dev/null -w '%{http_code}\n' https://<你的域名>/api/progress/health-check

# 2) 认证访问 WebDAV 目录列举：期望 207 Multi-Status
curl -s -o /dev/null -w '%{http_code}\n' \
  -u "user:$SESHAT_AUTH_TOKEN" -X PROPFIND -H 'Depth: 1' \
  https://<你的域名>/dav/
```

### 9.3 WebDAV 列表条数比对

```bash
# 第 2 步停机前记录过一次条数，此处再次执行，两者应一致
curl -s -u "user:$SESHAT_AUTH_TOKEN" -X PROPFIND -H 'Depth: 1' \
  https://<你的域名>/dav/ | grep -c '<D:response>'
```

### 9.4 三端同步验证

- **Emacs**：`M-x seshat-sync-now`，观察 minibuffer 与 `*Messages*` 中三阶段（拉取远端 → 计算差异 → 推送本地）的计数，与预期一致；冲突数符合预期。
- **Android**：手动触发一次同步，确认无错误、笔记可见。
- **git 历史**：`git -C <数据目录>/seshat log --oneline | head`，确认 `.git` 随目录改名后仍可用。

### 9.5 验收清单（可勾选）

- [ ] 第 0 步核对结果记录表已填写完整
- [ ] 第 1 步备份归档可 `tar -tzf` 读取，条数与源一致，校验和已记录
- [ ] 服务已停（旧 unit 名）
- [ ] 数据已 `cp -a` 复制到新名，`diff -rq` 无差异，旧件保留
- [ ] `config.yaml` 三个路径键指向新路径
- [ ] `secrets.env` 变量名已改为 `SESHAT_*`（仅键名核对，无值泄露）
- [ ] 系统用户/组已改为 `seshat:seshat`，数据/配置目录属主已更新
- [ ] unit 已改名 `seshat.service`，`User`/`Group`/`WorkingDirectory`/`EnvironmentFile`/`ReadWritePaths`/`ExecStart` 均正确
- [ ] `systemctl is-active seshat` 为 `active`
- [ ] REST 未认证返回 401、WebDAV `PROPFIND` 返回 207
- [ ] WebDAV 列表条数与迁移前一致
- [ ] Emacs `seshat-sync-now` 三阶段计数正常
- [ ] Android 重装后可成功同步
- [ ] 观察期开始，旧目录/旧 DB 文件保持原样未删

## 10. 第 8 步 · 回滚

迁移采用复制（旧件保留），因此回滚只需把配置与 unit 指回旧路径/旧名并重启。

```bash
# 1) 停服
sudo systemctl stop seshat

# 2) 配置指回旧路径（config.yaml 的 db.path / webdav.root / webdav.public 改回 ./data/notes*）
#    可直接恢复第 3 步的副本：
sudo cp -a config.yaml.pre-migration config.yaml

# 3) 系统用户/组改回 notes（若第 5 步已改）
sudo groupmod -n notes seshat
sudo usermod -l notes -d /srv/notes -m seshat
sudo chown -R notes:notes <数据目录>

# 4) unit 改回旧名
sudo mv /etc/systemd/system/seshat.service /etc/systemd/system/notes.service
sudo systemctl daemon-reload
sudo systemctl start notes
systemctl is-active notes        # 期望 active
```

> 若第 3 步为复制、旧数据文件仍在，回滚无需 `mv` 回旧名，只需把配置指回旧路径。

- **客户端回滚**：Emacs 变量值改回旧值（`~/notes`、`notes-head` 等），本地目录 `mv ~/seshat ~/notes`；Android 重装旧包 `com.notes.app` 并重配。
- **旧目录保留**：旧数据（`<数据目录>/notes`、`<数据目录>/notes.db`）在观察期内**保持原样**，作为回滚点；观察期确认无误后再手动清理。
- **DB 不回滚**：DB 改名只改路径指向，不涉及 schema；回滚只需把 `config.yaml` 的 `db.path` 指回旧文件名。

## 11. 附录 · A / B / C 三域完整新旧名称对照表

### A 域（品牌标识）

| 项 | 旧值 | 新值 | 载体 |
|---|---|---|---|
| Go module | `module notes` | `module seshat` | `go.mod` |
| Go import 前缀 | `notes/internal/...`、`notes/cmd/...` | `seshat/...` | 29 个 .go 文件 |
| Elisp 文件名 | `notes-{sync,sync-cmd,rest,conflict}.el` | `seshat-*.el` | `emacs/` |
| Elisp 包前缀 | `notes-*` | `seshat-*` | 4 个 .el 文件 |
| Android 源码包名 | `com.notes.app` | `com.seshat.app` | 38 个 .kt |
| Android 主题名 | `Theme.Notes` | `Theme.Seshat` | `themes.xml`、`AndroidManifest.xml` |
| Android 项目名 | `notes-android` | `seshat-android` | `settings.gradle.kts` |
| App 显示名 | `Notes` | `Seshat` | `strings.xml` |
| 二进制名 | `notes-server`、`notes-llmnode` | `seshat-server`、`seshat-llmnode` | `Dockerfile`、`docs/deploy.md` |
| 镜像/容器名 | `notes-server:local`、`container_name: notes` | `seshat-server:local`、`seshat` | `docker-compose.yml` |
| systemd unit 名 | `notes.service` | `seshat.service` | `deploy/seshat.service.example` |
| compose service 名 | `notes:`、`notes-llmnode` | `seshat:`、`seshat-llmnode` | `docker-compose.yml` |
| 备份产物名 | `notes-backup-*.tar.gz`、`notes-backup.log` | `seshat-backup-*` | `scripts/backup.sh` |
| 文档标题 | `# Notes — 个人笔记同步系统` | `# Seshat — 个人笔记同步系统` | `README.md` |
| 示例域名 | `notes.example.com` | `seshat.example.com` | 文档与代码注释 |

### B 域（运行时契约）

| 项 | 旧值 | 新值 | 载体 |
|---|---|---|---|
| DB 密钥变量 | `NOTES_DB_KEY` | `SESHAT_DB_KEY` | `config.go`、`seshat.env.example`、`gen-secrets.sh`、docs |
| 主令牌变量 | `NOTES_AUTH_TOKEN` | `SESHAT_AUTH_TOKEN` | `config.go`、`gen-secrets.sh` |
| 节点令牌变量 | `NOTES_NODE_TOKEN` | `SESHAT_NODE_TOKEN` | `config.go`、`cmd/llmnode/main.go` |
| LLM key 变量 | `NOTES_LLM_API_KEY` | `SESHAT_LLM_API_KEY` | `config.go`、`gen-secrets.sh` |
| 节点服务端地址变量 | `NOTES_SERVER_URL` | `SESHAT_SERVER_URL` | `cmd/llmnode/main.go`、`docker-compose.yml` |
| 日志级别变量 | `NOTES_LOG_LEVEL` | `SESHAT_LOG_LEVEL` | `cmd/server/main.go` |
| 运行用户/组 | `notes:notes` | `seshat:seshat` | `Dockerfile`、`seshat.service.example` |
| 密钥文件路径 | `/etc/notes/secrets.env` | `/etc/seshat/secrets.env` | `seshat.service.example`、`docs/deploy.md` |
| 部署工作目录 | `/srv/notes`、`/opt/notes`、`/var/lib/notes` | `/srv/seshat`、`/opt/seshat`、`/var/lib/seshat` | `docs/deploy.md`、`seshat.service.example` |
| LUKS 映射名 | `notes-data` | `seshat-data` | `docs/deploy.md` |

> 不改动：WebDAV 挂载点 `/dav`、REST 挂载点 `/api`、`OLLAMA_URL`、`OLLAMA_MODEL`、`NODE_NAME`、`DB_PATH`、`OBJECTS_DIR`。

### C 域（数据契约）

| 项 | 旧值 | 新值 | 载体 | 迁移方式 |
|---|---|---|---|---|
| 服务端 DB 文件 | `./data/notes.db` | `./data/seshat.db` | `config.go`、`config.example.yaml`、`backup.sh` | `cp -a` |
| 服务端笔记根 | `./data/notes` | `./data/seshat` | `config.go`、`config.example.yaml` | `cp -a`（含 `.git`） |
| 服务端 public 子树 | `./data/notes/public` | `./data/seshat/public` | `config.go`、`config.example.yaml` | 随笔记根移动 |
| 客户端远端目录 | `"notes"`（Emacs）、`notes/sample.org`（Android） | `"seshat"` | `seshat-sync.el`、`GtdActivity.kt` | 客户端配置 |
| 客户端本地目录 | `~/notes` | `~/seshat` | `seshat-sync.el` | `mv` |
| Emacs HEAD 文件 | `~/.emacs.d/notes-head` | `~/.emacs.d/seshat-head` | `seshat-conflict.el` | `mv` |
| WebDAV 用户名默认值 | `"notes"` | `"seshat"` | `seshat-sync.el`、`WebDavClient.kt` | 客户端配置 |
| 备份目录变量（可选） | `NOTES_DIR` | `SESHAT_DIR` | `backup.sh` | 脚本变量 |
| Android prefs 文件名 | `notes_sync_secure`、`notes_sync` | `seshat_sync_secure`、`seshat_sync` | `SecurePrefs.kt` | 新包名下自动生效 |

> 说明：保留项 `notes_fts`（FTS5 虚表名）、`ReviewNotes`（LLM 审查函数名）、中文「笔记」用词、Emacs `;; Keywords:` 中的 `notes` 等**不在本手册迁移范围**（属业务语义，非品牌标识）。
