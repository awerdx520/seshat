# 架构决策日志

记录重大架构决策，格式：日期 + 决策 + 理由。

## 2026-10-11 — 个人笔记系统初始决策

| # | 决策 | 理由 |
|---|---|---|
| 1 | 静态加密语义（服务端可读明文 + 磁盘/DB 加密） | 用户显式选择；需服务端做全文索引，E2EE 下无法索引 |
| 2 | 服务端 Go + Android Kotlin + 桌面 elisp | 用户显式选择；Go 单二进制部署、WebDAV 生态成熟 |
| 3 | 云 VPS 部署 | 用户显式选择；需外网可访问 |
| 4 | WebDAV 双重定位（内部同步 + 对外出口） | 用户显式选择；对外给外部应用使用 |
| 5 | 单用户访问控制 | 用户显式选择；简单令牌认证 |
| 6 | git 版本化 + ETag 乐观锁处理文本冲突 | 详见 docs/adr/0001-git-versioning-conflict-resolution.md；WebDAV 整文件替换模型 + 外部应用不受控 |
| 7 | 对外 WebDAV 可读写 + 范围受限 + 每次写自动 commit | 用户显式选择；外部应用需要读写能力 |
| 8 | LLM 后端：混合（云端 API + 本地处理节点），本地节点为纯推理节点、结果明文回传 | 用户显式选择；VPS 无算力跑本地模型，详见 docs/adr/0002-llm-hybrid-backend.md |
| 9 | 对外 WebDAV 的 ETag/索引按「挂载目录相对 repo 根偏移」计算 | code-reviewer 复审发现路径错位，加 offset 参数修正（详见 internal/webdav/versioned.go） |

## 2026-10-12 — 品牌改名：notes → Seshat

将项目品牌由 `notes` 更名为 `Seshat`，覆盖三个命名域，边界如下：

- **A 品牌标识域**：Go module 与 import 路径、Elisp 包前缀与文件名、Android 源码包名、App 显示名、二进制/镜像名、systemd unit 名、文档标题。属纯标识替换，改完编译即可验证。
- **B 运行时契约域**：环境变量 `NOTES_*` → `SESHAT_*`、systemd unit 名、compose service/container 名、运行用户/组名。需与部署端配置同步。
- **C 数据契约域**：数据目录与文件名（`./data/notes*` → `./data/seshat*`）、WebDAV 远端目录、客户端本地目录、prefs 文件名。属**数据迁移**，改完必须移动既有文件并同步客户端配置，否则运行时静默失效；迁移用复制（`cp -a`）而非移动，旧目录在观察期内保留作回滚点。

用户裁决（D1–D5；D1/D2/D3/D5 均为「乙」＝彻底改）：

| 编号 | 决策 | 选项 | 裁决 |
|---|---|---|---|
| D1 | Android `applicationId` | 甲：保留 `com.notes.app`；乙：改 `com.seshat.app`（新 App，需重装并重配令牌） | **乙**（彻底改） |
| D2 | 系统用户/组名 `notes` | 甲：保留；乙：改 `seshat`（需 usermod + 全量 chown + 停机） | **乙**（彻底改） |
| D3 | Android prefs 文件名 | 甲：保留 `notes_sync`/`notes_sync_secure`；乙：改 `seshat_sync`/`seshat_sync_secure` | **乙**（彻底改） |
| D4 | VPS 数据实况 | 需用户在 VPS 上回报实际值（`webdav.root`、客户端 `remote-dir`/`local-dir`、目录层级） | 待回报（不阻塞实施） |
| D5 | `NOTES_DIR` → `SESHAT_DIR` | 甲：保留；乙：改 | **乙**（彻底改） |

明确保留清单（禁止机械替换，L3 审计据此判定）：

- FTS5 虚表名 `notes_fts`（真实 DB 表名，改名需 DB 迁移且收益为零）；
- Go 函数 `ReviewNotes` 及其测试（LLM 审查能力函数名，属业务语义而非品牌）；
- 中文用词「笔记」「笔记目录」「笔记同步」（领域语义）；
- org 文件头 `Keywords`（语义头，非品牌）；
- `:notes:` tag（数据语义，可能已被真实笔记引用）。

理由：一次性彻底改名以避免长期两名并存的心智负担；C 域改名按数据迁移单独处理，以复制 + 观察期降低风险。完整方案与实施清单见 [openspec/active/seshat-rename.md](active/seshat-rename.md)。
