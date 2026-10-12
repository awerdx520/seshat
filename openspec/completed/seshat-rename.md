# Seshat 全仓改名（A + B + C 全域）+ VPS 数据迁移

## 当前状态

- 阶段：Phase 4（Review & Document）· **已完成**
- 已确认：方案 ✅（A+B+C 全域改名）；计划 ✅（用户确认）；D1–D5 裁决 ✅
- 实施：批次 1–6 + 收尾修复全部完成；Go `build`/`test`/`vet` 全绿、Elisp `check-parens` 4/4、Android `assembleDebug`+`testDebugUnitTest` 成功、部署脚本 `bash -n` 通过
- 审查：plan-reviewer 两轮（首轮 4 项 blocking → 修订 → 复审通过）；code-reviewer 有条件通过（1 项 important 备份时序问题已修复）
- 审计：全仓终态审计 A/B/C 三域**零遗漏**（唯一发现的 A 域遗漏 `internal/api/web/` 前端 4 行已修复）
- 下一步：无（已归档）

## 目标

把项目品牌从 `notes` 改为 `Seshat`，覆盖三个命名域（A/B/C），并产出一份可在 VPS 上手工执行的迁移 runbook。

- A 品牌标识：Go module、import 路径、Elisp 包前缀与文件名、Android 源码包名、App 显示名、二进制/镜像名、服务名、文档标题
- B 运行时契约：`NOTES_*` → `SESHAT_*` 环境变量、systemd unit 名、compose service/container 名、运行用户/组名
- C 数据契约：数据目录与文件名、WebDAV 远端目录、客户端本地目录、prefs 文件名

## 命名映射表（唯一事实来源）

### A 域 — 品牌标识

| 项 | 现值 | 目标值 | 载体 |
|---|---|---|---|
| Go module | `module notes` | `module seshat` | `go.mod:1` |
| Go import 前缀 | `notes/internal/...`、`notes/cmd/...` | `seshat/...` | 29 个 .go 文件 / 71 条 import |
| git 提交身份 | `identityName = "notes"`、`identityEmail = "notes@local"` | `seshat`、`seshat@local` | `internal/gitver/version.go:39,40` |
| 日志文案 | `"notes 服务启动"`、`"notes 服务退出"` | `"seshat 服务启动/退出"` | `cmd/server/main.go:64,148` |
| Elisp 文件名 | `notes-{sync,sync-cmd,rest,conflict}.el` | `seshat-*.el` | `emacs/` |
| Elisp 包前缀 | `notes-*`（含 `defgroup`/`:prefix`/`defvar`/`provide`/`require`/消息前缀/临时文件名前缀） | `seshat-*` | 4 个 .el 文件，241 处 |
| Android 源码包名 | `com.notes.app` | `com.seshat.app` | 38 个 .kt 的 `package` 行 + 目录树 |
| Android 主题名 | `Theme.Notes` | `Theme.Seshat` | `themes.xml:4`、`AndroidManifest.xml:12` |
| Android 项目名 | `rootProject.name = "notes-android"` | `"seshat-android"` | `settings.gradle.kts:19` |
| App 显示名 | `Notes` | `Seshat` | `strings.xml:3` |
| 二进制名 | `notes-server`、`notes-llmnode` | `seshat-server`、`seshat-llmnode` | `Dockerfile`、`docs/deploy.md` |
| 镜像/容器名 | `notes-server:local`、`container_name: notes` | `seshat-server:local`、`seshat` | `docker-compose.yml:21,22` |
| systemd unit 名 | `notes.service` | `seshat.service` | `deploy/notes.service.example`、`docs/deploy.md` |
| compose service 名 | `notes:`、`notes-llmnode` | `seshat:`、`seshat-llmnode` | `docker-compose.yml:19,42` |
| 备份产物名 | `notes-backup-*.tar.gz`、`notes-backup.log` | `seshat-backup-*` | `scripts/backup.sh:71,75,177` |
| 文档标题 | `# Notes — 个人笔记同步系统` | `# Seshat — 个人笔记同步系统` | `README.md:1` |
| 示例域名 | `notes.example.com` | `seshat.example.com` | 文档与代码注释 |
| 计划文件 | `openspec/completed/personal-notes-system.md` | `openspec/completed/personal-seshat-system.md`（可选） | 文件名 |

### B 域 — 运行时契约

| 项 | 现值 | 目标值 | 载体 |
|---|---|---|---|
| DB 密钥变量 | `NOTES_DB_KEY` | `SESHAT_DB_KEY` | `internal/config/config.go:24`、`deploy/notes.env.example:14`、`scripts/gen-secrets.sh:48`、6 份 docs |
| 主令牌变量 | `NOTES_AUTH_TOKEN` | `SESHAT_AUTH_TOKEN` | `config.go:26`、`gen-secrets.sh:51`、`internal/auth/auth.go`（package 注释） |
| 节点令牌变量 | `NOTES_NODE_TOKEN` | `SESHAT_NODE_TOKEN` | `config.go:32`、`cmd/llmnode/main.go:74,97,100`（实为 8+ 处，含注释与错误消息）、`internal/auth/auth.go`（package 注释） |
| LLM key 变量 | `NOTES_LLM_API_KEY` | `SESHAT_LLM_API_KEY` | `config.go:28`、`gen-secrets.sh:57` |
| 节点服务端地址变量 | `NOTES_SERVER_URL` | `SESHAT_SERVER_URL` | `cmd/llmnode/main.go:64,71`、`docker-compose.yml:45` |
| 日志级别变量 | `NOTES_LOG_LEVEL` | `SESHAT_LOG_LEVEL` | `cmd/server/main.go:43` |
| 运行用户/组（D2=乙） | `notes:notes` | `seshat:seshat` | `Dockerfile:67,68`、`deploy/notes.service.example:19,20` |
| 密钥文件路径 | `/etc/notes/secrets.env` | `/etc/seshat/secrets.env` | `deploy/notes.service.example:23`、`docs/deploy.md:142` |
| 部署工作目录 | `/srv/notes`、`/opt/notes`、`/var/lib/notes` | `/srv/seshat`、`/opt/seshat`、`/var/lib/seshat` | `docs/deploy.md`、`deploy/notes.service.example:21,33` |
| LUKS 映射名 | `notes-data` | `seshat-data` | `docs/deploy.md:57-65` |

**注**：WebDAV 挂载点 `/dav`、REST 挂载点 `/api`、`OLLAMA_URL`、`OLLAMA_MODEL`、`NODE_NAME`、`DB_PATH`、`OBJECTS_DIR` **不改**。

**明确保留清单（L3 审计据此判定，禁止机械替换）**：

| 保留项 | 位置 | 理由 |
|---|---|---|
| FTS5 虚表名 `notes_fts` | `internal/storage/db.go:82`（CREATE VIRTUAL TABLE）、`internal/index/index.go:3,33`（注释）、`internal/index/index.go:58,61,80,105`（SQL 中 4 处）、`internal/storage/db_test.go:137,144,150`（注释 + 2 处测试硬编码 SQL） | 真实 DB 表名，改名需 DB 迁移，收益为零；测试硬编码若误改会导致 `TestFTS5TableUsable` 失败 |
| Go 函数 `ReviewNotes` 及其测试 | `internal/llm/review.go:63`、`internal/llm/review_test.go`（8 个 `TestReviewNotes*` 函数） | LLM 审查能力函数名，业务语义而非品牌 |
| 中文用词「笔记」「笔记目录」「笔记同步」 | 全部代码注释与文档叙述 | 领域语义，改名后读起来才通顺 |
| Emacs `;; Keywords:` 头中的 `notes` | `emacs/seshat-rest.el:6`、`emacs/seshat-sync-cmd.el:6`、`emacs/seshat-conflict.el:6` | Emacs 包分类关键词（标记「笔记类」），`seshat` 作 keyword 无分类意义 |
| 示例数据中的 `:notes:` tag | `android/app/src/main/assets/sample.org:2`、`android/app/src/test/java/com/seshat/app/gtd/OrgEditorTest.kt:19` | 数据语义 tag，可能已被真实笔记引用 |
| 测试用任意文件名 `notes.txt` | `android/app/src/test/java/com/seshat/app/importer/BookImporterTest.kt:46` | 任意测试输入，非品牌引用 |

### C 域 — 数据契约（每一项都需迁移）

| 项 | 现值 | 目标值 | 载体 | 迁移风险 |
|---|---|---|---|---|
| 服务端 DB 文件 | `./data/notes.db` | `./data/seshat.db` | `config.go:39`、`config.example.yaml:17`、`backup.sh:36`、`config_test.go` | 与笔记根同级，非嵌套 |
| 服务端笔记根 | `./data/notes` | `./data/seshat` | `config.go:40`、`config.example.yaml:22` | **内含 `.git/` 版本库** |
| 服务端 public 子树 | `./data/notes/public` | `./data/seshat/public` | `config.go:41`、`config.example.yaml:24` | **嵌套在笔记根内**，随根移动 |
| 客户端远端目录 | `notes-sync-remote-dir "notes"`、Android `REMOTE_PATH "notes/sample.org"` | `"seshat"` | `notes-sync.el:53`、`GtdActivity.kt:265` | **与服务端 root 是两层独立命名，见 D4** |
| 客户端本地目录 | `notes-sync-local-dir "~/notes"` | `"~/seshat"` | `notes-sync.el:48` | 本地数据迁移 |
| Emacs HEAD 文件 | `~/.emacs.d/notes-head` | `~/.emacs.d/seshat-head` | `notes-conflict.el:42` | 状态文件，丢失会触发重新比对 |
| WebDAV 用户名默认值 | `notes-sync-username "notes"`、Android `DEFAULT_USER = "notes"` | `"seshat"` | `notes-sync.el:38`、`WebDavClient.kt:38` | **服务端忽略用户名，仅本地默认值，安全** |
| 备份目录变量（可选） | `NOTES_DIR` | `SESHAT_DIR` | `backup.sh:37` | 属脚本内部变量，可选改 |
| Android prefs 文件名（D3=乙） | `notes_sync_secure` / `notes_sync` | `seshat_sync_secure` / `seshat_sync` | `SecurePrefs.kt:59,62` | 用户已确认接受配置丢失（新包名下本无历史数据，`LEGACY_PREFS` 仅保持形式统一） |

## 关键设计决策

- **D1 三层域分离**：A/B 域是纯标识替换（改完编译即验证）；C 域是**数据迁移**（改完必须移动文件 + 改客户端配置，否则运行时静默失效）。三类任务分批执行、分批验证，不混在一批里。
- **D2 系统用户/组名（待确认，推荐：保留）**：`notes` 只是 Linux 账户名，改成 `seshat` 需 `usermod`/`groupmod` + 全量 `chown -R` + 改 unit 的 `User/Group/ReadWritePaths` + 停服务，且失败会导致服务无法启动。收益仅为"字符串彻底"。**推荐保留**；若选改，runbook 中单独成节，含停机步骤与回滚。
- **D3 Android prefs 文件名（待确认，推荐：保留）**：`SecurePrefs.kt` 的 `LEGACY_PREFS = "notes_sync"` 是**既有迁移逻辑的来源**（明文 → 加密）。改文件名会切断这条迁移链。**推荐保留**（prefs 文件名是内部实现细节，用户不可见）。
- **D4 双层嵌套核对（强制前置）**：服务端 `webdav.root` 与客户端 `remote-dir` 是两层独立命名，且 Emacs 默认 `"notes"` 与 Android 默认 `"/"` 本就不一致，说明实际部署已自定义。**迁移第 0 步必须在 VPS 与客户端上核对真实值**（见 runbook），不得按默认值推断。
- **D5 迁移用复制而非移动**：VPS 上用 `cp -a` 而非 `mv`，服务重启验证通过并观察一个同步周期后，才删除旧目录。旧目录保留期间作为事实上的回滚点。
- **D6 迁移前强制备份**：执行任何迁移前，用 `scripts/backup.sh` 产出完整备份并校验归档可读。
- **D7 不回滚数据库**：DB 文件名改名只影响"路径指向"，不涉及 schema；若回滚，只需把配置指回旧文件名。

## 任务列表

### 批次 1 — Go 服务端（A + B 域，可编译验证）

- [x] T1.1 `go.mod` module 行 `notes` → `seshat`；全仓 29 个 .go 文件的 import 路径 `notes/internal`/`notes/cmd` → `seshat/internal`/`seshat/cmd`（含 17 个测试文件）
- [x] T1.2 `internal/config/config.go`：4 个 `env*Key` 常量值改 `SESHAT_*`；3 个 `default*Path` 改 `./data/seshat.db`、`./data/seshat`、`./data/seshat/public`
- [x] T1.3 `cmd/server/main.go`：`envLogLevel` 值改 `SESHAT_LOG_LEVEL`；两处日志文案改 seshat；注释同步
- [x] T1.4 `cmd/llmnode/main.go`：**全部** `NOTES_*` 引用改 `SESHAT_*`（实测 8+ 处，含包注释、环境变量读取、错误消息字符串如「环境变量 NOTES_SERVER_URL 未设置」）；注释示例域名改 `seshat.example.com`
- [x] T1.5 `internal/gitver/version.go`：`identityName`/`identityEmail` 改 `seshat` / `seshat@local`
- [x] T1.6 同步受影响测试断言：`internal/config/config_test.go`（3 个默认值断言）、`internal/api/node_auth_test.go`、`internal/api/versions_test.go`、`cmd/llmnode/main_test.go` 等所有断言 `NOTES_*` 与 `./data/notes*` 的位置
- [x] T1.7 注释与文案系统同步：41 个含 `notes` 的 .go 文件中所有品牌性注释/文案改为 seshat（判定规则：英文 `notes 服务`/`notes.db`/`notes.example.com` → `seshat`；`internal/auth/auth.go` 的 package 注释中 `NOTES_AUTH_TOKEN`/`NOTES_NODE_TOKEN` 同步改；中文「笔记」保留）
- [x] T1.8 验证：`go build ./...` + `go test ./...` 全绿
（依赖：无）

### 批次 2 — Elisp 客户端（A + C 域）

- [x] T2.1 `git mv` 4 个文件：`notes-sync.el`→`seshat-sync.el`、`notes-sync-cmd.el`→`seshat-sync-cmd.el`、`notes-rest.el`→`seshat-rest.el`、`notes-conflict.el`→`seshat-conflict.el`
- [x] T2.2 替换全部 `notes-` 前缀（函数名、变量名、`defgroup`、`:prefix`、`provide`、`require`、消息前缀 `"notes-sync: "`、临时文件名前缀 `"notes-sync-"`/`"notes-remote-"`/`"notes-base-"`、buffer 名 `*notes-conflict %s*`、`--timer` 变量）
- [x] T2.3 文件头 `;;; xxx.el ---` 行与 `;; Copyright (C) 2025 notes project` 同步改名
- [x] T2.4 C 域默认值：`seshat-sync-local-dir "~/seshat"`、`seshat-sync-remote-dir "seshat"`、`seshat-sync-username "seshat"`、`seshat-conflict-local-head-file "~/.emacs.d/seshat-head"`（含 docstring 内引用）
- [x] T2.5 验证：`elisp_check_parens` 4 个文件全通过；`elisp_trigger_flymake_check` + `get_flymake_diagnostics` 无 error；若仓库有 ERT 测试则运行
（依赖：无，可与批次 1 并行）

### 批次 3 — Android（A + C 域）

- [x] T3.1 `git mv` 目录：`src/main/java/com/notes/` → `src/main/java/com/seshat/`、`src/test/java/com/notes/` → `src/test/java/com/seshat/`（保留末级 `app/`）
- [x] T3.2 38 个 .kt 的 `package com.notes.app...` → `com.seshat.app...`
- [x] T3.3 全部 `import com.notes.app.*` 与全限定引用（`MainActivity.kt:9-12`、`SecurePrefs.kt:23` 注释、`SyncManager.kt:3-10`、`SyncManagerTest.kt:262`、`SecurePrefsTest.kt:3`、`PdfReaderActivity.kt:191` 的 `EXTRA_URI` 字符串）同步替换
- [x] T3.4 `build.gradle.kts:20` `namespace = "com.seshat.app"`；`build.gradle.kts:36` `applicationId = "com.seshat.app"`（D1=乙：新包名 ⇒ 手机上为全新 App，需卸载旧版重装并重新输入服务端地址与令牌）
- [x] T3.5 `settings.gradle.kts:19` → `"seshat-android"`；`strings.xml:3` → `Seshat`；`themes.xml:4` + `AndroidManifest.xml:12` → `Theme.Seshat`
- [x] T3.6 C 域默认值：`WebDavClient.kt:38` `DEFAULT_USER = "seshat"`、`GtdActivity.kt:265` `REMOTE_PATH = "seshat/sample.org"`、`SecurePrefs.kt:59` `ENCRYPTED_PREFS = "seshat_sync_secure"`、`SecurePrefs.kt:62` `LEGACY_PREFS = "seshat_sync"`（D3=乙；注释同步说明新包名下无历史明文数据）
- [x] T3.7 测试内的示例域名与路径（`SecurePrefsTest.kt`、`NotesConfigTest.kt:11-21`、`WebDavClientTest.kt:49-119`）同步为 seshat；并同步注释残留：`GtdActivity.kt:195,264`（`NOTES_AUTH_TOKEN` 注释、`<serverUrl>/dav/notes/sample.org`）、`SecurePrefs.kt:14,67`（`NOTES_AUTH_TOKEN` 注释）
- [x] T3.8 **类名与文件名改名（首轮审查发现的遗漏项）**：`git mv NotesConfig.kt SeshatConfig.kt`、`git mv NotesConfigTest.kt SeshatConfigTest.kt`；`data class NotesConfig` → `SeshatConfig`、`class NotesConfigTest` → `class SeshatConfigTest`；同步 6 个引用文件（`RestClient.kt`、`WebDavClient.kt`、`GtdActivity.kt`、`WebDavClientTest.kt`、`RestClientTest.kt` 及测试类自身），实测共 16 处引用
- [x] T3.9 示例数据 `android/app/src/main/assets/sample.org` 品牌文案处置（复审发现的遗漏项）：第 4 行 `* 项目：Notes 应用` → `* 项目：Seshat 应用`；第 2 行 `#+FILETAGS: :notes:` 的 tag **默认保留**（属数据语义，可能已被真实笔记引用），改与不改由用户在批次 6 runbook 的启动阶段决定
- [x] T3.10 验证：`./gradlew :app:assembleDebug` 与 `./gradlew :app:testDebugUnitTest` 通过（若 SDK 不可用，标注"环境不可用，回退静态核对"，并逐文件复核 package/import 一致性）
（依赖：无，可与批次 1/2 并行）

### 批次 4 — 部署工件与脚本（A + B 域）

- [x] T4.1 `Dockerfile`：镜像标签、构建产物名 `seshat-server`/`seshat-llmnode`、`COPY`/`ENTRYPOINT`、运行用户组改为 `seshat`（D2=乙：`groupadd`/`useradd` 与 `install -d -o seshat -g seshat /app/data`）、注释文案
- [x] T4.2 `docker-compose.yml`：service 名 `seshat`、`container_name`、`image`、两个 llmnode 注释块、环境变量键名注释
- [x] T4.3 `deploy/notes.env.example` → `git mv` 为 `deploy/seshat.env.example`，4 个变量名改 `SESHAT_*`
- [x] T4.4 `deploy/notes.service.example` → `git mv` 为 `deploy/seshat.service.example`，改 unit 名引用、`Description`、`Documentation`、`User`/`Group` 改为 `seshat`（D2=乙）、`WorkingDirectory`、`EnvironmentFile`、`ReadWritePaths`；**顺带修正 R4**：现行 `ExecStart=/usr/local/bin/notes server` 错误（多余子命令且二进制名不符），明确改为 `ExecStart=/usr/local/bin/seshat-server`（**无子命令**；依据：`Dockerfile` 的 `ENTRYPOINT ["/usr/local/bin/notes-server"]`，且 `cmd/server/main.go` 的 `main()` 直接调 `run()`、不解析任何子命令）
- [x] T4.5 `scripts/gen-secrets.sh`：4 个输出变量名改 `SESHAT_*`、注释文案、末尾提示路径
- [x] T4.6 `scripts/backup.sh`：`notes_dir` 默认值 `./data/seshat`、`db_path` 默认值 `./data/seshat.db`、产物名 `seshat-backup-*`、MANIFEST 文案；**补首轮遗漏**：`mktemp -d` 临时目录模板 `notes-backup.XXXXXX`（:75）、文件头注释「backup.sh — notes 服务数据备份脚本」、用法说明中的「笔记目录（默认 ./data/notes）」；`NOTES_DIR` 改 `SESHAT_DIR`（D5=乙，含脚本内引用与用法注释同步）
- [x] T4.7 `config.example.yaml`：`db.path`/`webdav.root`/`webdav.public` 三个默认值改 seshat；注释中的变量名与标题改 seshat
- [x] T4.8 `.dockerignore`：产物名排除项同步（`notes-server`→`seshat-server` 等）
- [x] T4.9 验证：`bash -n` 两个脚本语法通过；`docker compose config` **不执行**（会展开环境变量，违反密钥规则），改为人工比对键名一致性；确认全仓再无 `NOTES_` 变量名残留（grep）
（依赖：无）

### 批次 5 — 文档（A + B + C 域）

- [x] T5.1 `README.md`：标题、正文服务名、**修正 R4 悬空引用**（`openspec/active/personal-notes-system.md` → 实际 `completed/` 路径）
- [x] T5.2 `docs/deploy.md`（99 处）：服务名命令、二进制名、路径、变量名、unit 名、示例域名、LUKS 映射名
- [x] T5.3 `docs/backup.md`（38 处）：路径、变量名、归档名、systemctl 命令
- [x] T5.4 `docs/security.md`（25 处）：变量名清单表、密钥路径、命令
- [x] T5.5 `docs/configuration.md`（13 处）、`docs/llm.md`（9 处）、`docs/api.md`（8 处）、`docs/errors.md`（1 处）：变量名、默认值、叙述文案（保留 `ReviewNotes`）
- [x] T5.6 `CHANGELOG.md`：新增本次改名条目（Keep a Changelog 格式，标注 Breaking Change）；历史条目不改
- [x] T5.7 `openspec/decisions.md`：新增决策记录（改名 + 三层域边界 + D1~D6）
- [x] T5.8 `openspec/tech-debt.md`：更新其中的文件名与变量名引用
- [x] T5.9 `openspec/completed/personal-notes-system.md` 文件名是否改（可选，见映射表备注）
- [x] T5.10 验证：grep 全仓 `NOTES_` 与 `notes-server`/`notes.service`/`/srv/notes` 应仅剩历史叙述与"不改清单"内的项；逐项核对
（依赖：批次 1-4 完成，因文档需引用最终确定的名称）

### 批次 6 — VPS 迁移 runbook

- [x] T6.1 编写 `docs/migration-seshat.md`：含前置核对、备份、停机、目录改名、配置改名、服务名与用户改名（D2=乙：用户/组改为 `seshat`）、客户端改动、验证、回滚，全部命令以占位路径书写，**不含任何密钥值**
- [x] T6.2 前置核对清单（第 0 步，必须在 VPS 上执行并回报实际值）：`webdav.root` 与 `public` 的实际路径、客户端两组 `remote-dir`/`local-dir` 的实际值、数据目录实际布局（`ls` 层级）、`.git` 仓库位置、运行用户
- [x] T6.3 迁移步骤：备份 → `systemctl stop` → `cp -a` 目录与 DB 文件改名 → 改 `config.yaml` 路径 → 改 `/etc/*/secrets.env` 变量名 → 改 unit 文件与 `daemon-reload` → 改客户端配置（Emacs 变量 + Android 设置）→ 启动 → 验证
- [x] T6.4 验证命令：`systemctl is-active`、`curl` 健康检查（用变量引用而非明文）、WebDAV `PROPFIND` 列表核对、Emacs `M-x seshat-sync-now` 三阶段计数、Android 手动同步
- [x] T6.5 回滚节：配置指回旧路径 + `mv` 回旧名 + `daemon-reload` + 启动；并说明旧目录在观察期内保留
- [x] T6.6 系统用户/组改名迁移步骤（D2=乙）：停机窗口内依次执行 `groupmod`/`usermod` 改名、家目录调整、对数据目录与配置目录 `chown -R seshat:seshat`、unit 文件 `User`/`Group`/`ReadWritePaths` 同步、`systemctl daemon-reload`；含失败即回滚（改回 `notes`）的步骤
- [x] T6.7 Android 客户端迁移步骤（D1/D3=乙）：卸载旧 App → 安装 `com.seshat.app` 新包 → 重新输入服务端地址与令牌（令牌从 VPS 的 `secrets.env` 读取，**不得写入文档或任何文件**）→ 验证同步
（依赖：批次 1-5；实际执行由用户在 VPS 上手工完成，本计划只产出 runbook）

## 验证标准

- **L1（每批必过）**：Go `go build ./...` + `go vet`；Elisp `check-parens` + Flymake 无 error；Shell `bash -n`；文件级 grep 无遗漏（对照命名映射表逐项）
- **L2（分批后）**：`go test ./...` 全绿；`./gradlew :app:testDebugUnitTest` 通过（不可用则标注回退）；Elisp ERT（若存在）
- **L3（全部完成后）**：全仓 grep `notes` 的分类审计——输出每个残留命中，人工判定属"A 域遗漏 / B 域遗漏 / C 域遗漏 / 保留项"，零遗漏为止
- **迁移验证（VPS，用户执行）**：服务 active、健康检查 200、WebDAV 列表与迁移前一致、三端各完成一次成功同步

## 文档清单

| 文档 | 是否受本次影响 |
|---|---|
| `README.md` | 是（标题 + 悬空引用） |
| `docs/architecture.md` | 否（无 notes 命中，仅叙述"笔记"） |
| `docs/deploy.md` | 是（99 处，核心） |
| `docs/backup.md` | 是（38 处） |
| `docs/security.md` | 是（25 处） |
| `docs/configuration.md` | 是（13 处） |
| `docs/llm.md` | 是（9 处） |
| `docs/api.md` | 是（8 处） |
| `docs/errors.md` | 否（仅叙述） |
| `docs/adr/0001-*.md`、`0002-*.md` | 否 |
| `CHANGELOG.md` | 是（新增条目） |
| `openspec/decisions.md` | 是（新增决策） |
| `openspec/tech-debt.md` | 是（引用更新） |
| `config.example.yaml` | 是（默认值） |
| `deploy/*.example` | 是（文件名 + 内容） |
| `docs/migration-seshat.md` | 新建 |

## 注意事项（陷阱）

1. **头号陷阱**：`notes-sync-username` 这类**变量名属 A 域（要改）**，但它的**默认值 `"notes"` 属 C 域（也要改，但改的理由不同、且需与客户端/服务端一致）**。机械替换两者一起改是对的，但必须确认服务端是否校验用户名（已确认：**服务端忽略用户名**，风险低）。
2. **两层嵌套**：服务端 `webdav.root` 与客户端 `remote-dir` 同时改名后，实际路径会变成 `<root>/seshat/...`。若 VPS 上笔记原本直接在 root 下（无 `notes/` 这一层），则客户端改动会指向不存在的目录。**必须先核对 D4**。
3. **`.git/` 在笔记根内**：目录改名后 `gitver.Open(root)` 会打开新路径。go-git 不依赖绝对路径，但需确认 `.git/config` 内无绝对路径（未检查项），迁移后跑一次 `git log` 验证。
4. **Android 若要改 applicationId**：等于新 App，用户需重新输入服务端地址与 token（token 在 VPS 的 `secrets.env` 中）。必须先在确认门禁中让用户明确接受。
5. **`docker compose config` 禁止执行**：会展开 `${VAR}` 并可能把密钥带入输出，违反密钥保护规则。验证键名用文本比对。
6. **不得读取**：`data/secrets.env`、`android/keystore.properties`、`android/release.keystore`、任何 `.env`。所有涉及密钥的操作只处理**键名**。
7. **`android/app/build/**` 是构建产物**，无需手改，重新构建即可；不要把它计入改动清单。
8. **历史 CHANGELOG 条目不回改**，只在顶部新增改名条目（否则伪造历史）。
9. 改名后 `git` 历史提交的作者身份不变（只影响后续提交），无需 `filter-branch`。
10. **`notes_fts` 虚表名与 `ReviewNotes` 函数名禁止替换**：前者是 FTS5 真实表名（`internal/storage/db.go:82`、`internal/index/index.go` 4 处 SQL），机械替换会导致 SQL 与现有数据库不匹配、全文索引失效；后者是 LLM 审查能力函数名。二者已在映射表「明确保留清单」中声明，L3 审计须据此判定而非零残留。

## 回滚方案

- **代码层**：本计划全部在 git 工作区内进行，批次间以提交为界；任何批次验证失败即 `git checkout` 该批次的改动（Phase 3 开始时先创建安全点）。
- **数据层**：迁移采用 `cp -a` 复制（D5），旧目录与旧 DB 文件在观察期内保留原样，回滚只需把配置指回旧路径并重启。
- **客户端层**：Emacs 与 Android 的客户端改动是本地配置，回滚即改回旧值（旧目录保留期间数据仍可用）。

## 用户裁决（已确认）

| 编号 | 决策 | 选项 | 裁决 |
|---|---|---|---|
| **D1** | Android `applicationId` | 甲：保留 `com.notes.app`；乙：改 `com.seshat.app`（新 App，需重配 token） | **乙**（用户已确认接受重装与重配） |
| **D2** | 系统用户/组名 `notes` | 甲：保留；乙：改 `seshat`（需 usermod + 全量 chown + 停机） | **乙**（用户已确认接受停机迁移） |
| **D3** | Android prefs 文件名 | 甲：保留；乙：改 `seshat_sync_secure`/`seshat_sync` | **乙**（用户已确认接受配置丢失） |
| **D4** | VPS 数据实况 | 需用户提供：`webdav.root` 实际值、客户端 `remote-dir`/`local-dir` 实际值、数据目录层级 | 待用户在 VPS 上回报 |
| **D5** | `NOTES_DIR` → `SESHAT_DIR` | 甲：保留变量名；乙：改 | **乙** |
