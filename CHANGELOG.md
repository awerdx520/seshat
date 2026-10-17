# Changelog

本项目所有值得注意的变更记录于此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- 引入 `emacs/seshat-reader/`：vendor 自 emacs-reader（上游 commit `df3766e`），作为自研 Emacs 阅读器包的基础；包含「整页文本提取」与「页面矩形取文」两个新增能力，以及页号索引修复与 NaN 矩形防护。
- 新增阅读器鼠标选区取文模块 `emacs/seshat-reader/seshat-reader-select.el`：拖拽框选文本并取出内容（仅支持未旋转页面）。
- 新增 Emacs 侧批注采集与侧车同步（M11.3）：新模块 `emacs/seshat-reader/seshat-reader-annotation.el`（选区 → `C-c C-a` 建批注；`C-c C-l` 列表、`RET` 跳页、`d` 删除），`document_id` = `<标签>:<相对路径>`、`location` = `page:<n>;rect:…`；`emacs/seshat-rest.el` 新增 `seshat-rest-update-annotation`；`emacs/seshat-reader/Makefile` 加 `-L ..`（编译期可见顶层 `seshat-rest`）；新增 ERT 测试 `emacs/tests/seshat-reader-annotation-test.el`（17 用例，全绿）。修复「非 2xx 被静默当成无批注」的缺口（批注模块自行判状态码，区分空结果与失败）。**L3 端到端待服务端可用时补验。**
- 新增阅读器翻译/解释（M11.5）：新模块 `emacs/seshat-reader/seshat-reader-translate.el`——`C-c C-t` 翻译鼠标选区、`C-c C-e` 做 LLM 解释（译文/结果均经 posframe 弹出），`M-x seshat-reader-translate-save-as-annotation` 把最近一次结果存为服务端批注（复用 M11.3 链路）；翻译/解释复用本地 **go-translate（gt）**（翻译预设 `reader` = youdao-dict + google、解释预设 `reader-explain` = `gt-chatgpt-engine`，可指向任意 OpenAI 兼容端点）与 posframe，**不经过服务端 LLM 层**（服务端尚未暴露客户端 HTTP 接口）。新增 ERT 测试 `emacs/tests/seshat-reader-translate-test.el`（20 用例，全绿）。thomas-emacs 侧新增 `reader` / `reader-explain` 两个 gt 预设（位于用户配置，非本仓库）。
- 新增提交前密钥防护：`.pre-commit-config.yaml` 内置 `gitleaks`（暂存区内容扫描）与 `no-secret-files`（keystore / env / 私钥文件名黑名单，拦截 `.gitignore` 忽略文件被 `git add -f` 强制添加）两个本地钩子；根 `.gitignore` 补 `*.keystore`/`*.jks`/`*.p12`/`*.pfx`；安装与边界说明见 `docs/security.md` §6。
- 新增批注离线优先与自动同步（M11.6）：新模块 `emacs/seshat-reader/seshat-reader-annotation-queue.el`——服务端不可用时批注的创建/删除写入本地队列（`~/.local/share/seshat/annotation-queue.eld`，原子写），恢复后自动推进同步（启动后延迟首次 + 周期 + 手动 + 机会性）；`emacs/seshat-reader/seshat-reader-annotation.el` 三接入点改造（离线入队、列表合并展示本地项并标 `[待同步]`、按 uuid 取消本地待同步项）；同步侧幂等（create 比对已有 `(location, text)` 去重、delete 的 404 视为成功）。新增 ERT 测试 `emacs/tests/seshat-reader-annotation-queue-test.el`（23 用例，全绿）。**服务端零改动。**
- 新增阅读器双向引用（M11.4）：新模块 `emacs/seshat-reader/seshat-reader-reference.el`——注册 `seshat:` org 链接协议（`:follow` 打开书籍并跳页、`:store` 集成 `org-store-link`，链接格式 `seshat:<doc-id>#<location>`）；阅读器内 `C-c C-r` 把鼠标选区摘录插入笔记文件，批注列表 buffer 内 `C-c C-r` 插入该条批注的引用（服务端项与本地待同步项均支持，取值不触网）。**服务端零改动**，vendored 文件零改动（对 `annotation.el` 仅新增一处文本属性）。新增 ERT 测试 `emacs/tests/seshat-reader-reference-test.el`（29 用例，全绿）。
- 新增阅读器底部信息面板（M11.7）：新模块 `emacs/seshat-reader/seshat-reader-sidebar.el`——pop 式底部弹出面板（`seshat-reader-sidebar-position` 可配 `below-selected`/`at-bottom`），单窗口 + per-kind 高度记忆（切换批注/译文各自恢复高度），`post-command-select-window` 实现光标跟随（`seshat-reader-sidebar-select-window` 可关），并提供 popper 分流显示函数（`seshat-reader-sidebar-buffer-p` / `seshat-reader-sidebar-display-buffer`）；批注列表与译文/解释统一投递到该面板，不再抢占阅读窗口、不再自动消失。新增 ERT 测试 `emacs/tests/seshat-reader-sidebar-test.el`（18 用例，全绿）。
- 新增 ETAF 渲染层（M11.9，可选）：新模块 `emacs/seshat-reader/seshat-reader-etaf.el`——批注卡片化（页码徽章、`[待同步]` 标记、选中高亮、单行截断摘要）与译文排版（可折叠原文、分段正文、存为批注按钮），交互走 ETAF `:keys`（`RET`/`d`/`C-c C-r`/`q`）；配色用内置双色板随 `background-mode` 明暗自适应；ETAF 不可用或被关闭时自动回退纯文本渲染，功能不受影响。新增 ERT 测试 `emacs/tests/seshat-reader-etaf-test.el`（16 用例，全绿）。
- 译文/解释面板的**高度自适应**（M11.10，2026-10-18）：新增 `seshat-reader-sidebar-max-height`（默认 `0.8`），仅对 `translate` 且未挂载 ETAF runtime 的面板按内容行数（`window-text-pixel-size` 换算，夹紧 5 行–`0.8×frame`）调整窗口高度，成功后写入 per-kind 高度记忆；批注列表仍用固定高度 `seshat-reader-sidebar-height`。同帧内面板增高会压缩上方阅读窗口（预期）。
- 批注列表**分页**（M11.10，2026-10-18）：新增 `seshat-reader-annotation-page-size`（默认 `20`）与 buffer-local 当前页；`]` / `[` 翻页（ETAF `:keys` 与 `list-mode-map` 双路径），标题徽章多页显示「第 x/y 页」、单页显示「N 条」，`n` / `p` 跨页时自动切页，删除/刷新后页号收敛；纯文本回退路径页脚 `-- 第 x/y 页 --` 仅在多页时显示。
- 译文/解释面板**可选显示原文**（M11.10，2026-10-18）：新增 `seshat-reader-translate-show-source`（默认 `nil`），非 nil 时在正文前插入选中原文的 Markdown 引用块（每行 `> ` 前缀、不截断）。

### 变更

- `emacs/seshat-reader`：完成自研化改名（`reader` → `seshat-reader`），feature / 符号 / 文件名 / C 模块可见名统一为 `seshat-reader-*` 与 `seshat-render-core`；构建产物改为 `seshat-render-core.so` + `seshat-reader-autoloads.el`。
- `emacs/seshat-reader/seshat-reader-select.el`：引用随之更新（鼠标选区取文功能不变）。
- 验证：`make clean && make all` 通过；独立 Emacs 进程文本提取与 `pdftotext` 归一化后逐字一致；断言 7/7。

- Android 端构建源切换为国内镜像：`android/settings.gradle.kts` 的插件与依赖仓库改为阿里云镜像优先（官方源保留兜底），`gradle/wrapper/gradle-wrapper.properties` 的 Gradle 分发包仍为官方源（`services.gradle.org`），仅版本 `8.11 → 8.14.5`；AGP `8.5.2 → 8.13.2`；依赖版本与构建语义不变，已验证依赖解析无国外源请求、`assembleDebug` 构建通过。
- M11.5 收尾修复：`reader-explain` 改用解释 prompt（不再误用翻译模板）、`gt-posframe-pop-render-timeout` 由 30s 调至 90s（展示时长与引擎请求超时对齐；注意 `gt-posframe-pop-render-timeout` 为**全局**变量，调至 90 秒后影响所有 gt posframe（word/sentence/paragraph/reader 等），不只是阅读器解释）、用户配置 `gt-htt-proxy` 拼写修正为 `gt-http-proxy`。
- **破坏性**：`seshat-reader-translate-render` 默认值由 `pop` 改为 `sidebar`——译文/解释默认渲染到底部面板（`seshat-reader-sidebar`）而非 posframe，避免 posframe 抢焦点与自动消失；可用 defcustom 切回 `pop`（posframe）/`pin`，或设 `seshat-reader-sidebar-enabled` 为 `nil` 退回旧行为。
- `emacs/seshat-reader/Makefile`：新增可选 ETAF 依赖探测（`ETAF_ROOT ?= $(HOME)/WorkSpace/emacs-taf`），存在时把四仓库根与各自 `lisp/` 加入 `-L`；不存在时从编译与 checkdoc 列表中剔除 `seshat-reader-etaf.el`（`etaf-view` 为宏，编译期必须有 etaf-ui）。
- `emacs/seshat-reader/` 包内新增 3 个自研扩展模块（`seshat-reader-reference.el` / `seshat-reader-sidebar.el` / `seshat-reader-etaf.el`），`VENDORED.md` 自研扩展表同步。
- **阅读器面板渲染重构（M11.10，2026-10-18）**：译文/解释改为**面板内只读 Markdown 文本 buffer 完整渲染**——gt 只渲染到隐藏中转 buffer ` *Seshat gt*`（`:window-config` = `display-buffer-no-window` + `allow-no-window`），`:then` 回调取纯文本写入展示 buffer，以 `gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链显示（原生折行/滚动/复制/isearch）；`header-line` 显示「Seshat 译文」/「Seshat 解释」，面板内 `q`（关面板）/`C-c C-s`（存为批注）改由 minor mode `seshat-reader-translate-panel-mode` 承载。**删除**「来源：第 N 页」行与自绘「q 关闭」提示；`seshat-reader-translate-render` 的 `sidebar` 语义随之更新（面板内 Markdown 文本 buffer，非 ETAF 排版），`pop`/`pin` 仍为 posframe 回退。`seshat-reader-sidebar-translate-buffer-name` 改为**展示 buffer** 名（不再作 gt `:name` 与捕获守卫）。**ETAF 渲染层收敛为批注卡片**：译文排版组件树与 `seshat-reader-etaf-render-translate` 删除（`seshat-reader-etaf.el` 929 → 690 行），ETAF 只渲染批注列表 + 分页。

### 修复

- 批注列表在 ETAF 已挂载时不再 `erase-buffer`（改为交给渲染层增量刷新）：此前任何刷新路径（含 uuid 删除）都会触发 `etaf-runtime-flush` 报 `Args out of range: 20, 20`，并整块降级为纯文本渲染。
- 译文面板「来源：第 x 页」重复：正文管线渲染前剔除所有以 `来源：` 开头的行（gt 提取失败时会回退整个 buffer-string，把头部行与正文一起带出）；原文展开区不过滤，保持忠实摘录。**M11.10（2026-10-18）起该过滤器与「来源」行一并从代码中删除**——面板 Markdown 路径不再生成「来源」行，也不再自绘「q 关闭」提示（键位由 minor mode `seshat-reader-translate-panel-mode` 承载）。

## [0.2.0] - 2026-10-12

### 变更（Breaking Change）

项目品牌由 `notes` 更名为 `Seshat`。本次为**破坏性变更**，升级前务必按 [`docs/migration-seshat.md`](docs/migration-seshat.md) 执行迁移；改名的方案、命名映射与用户裁决见 [`openspec/active/seshat-rename.md`](openspec/active/seshat-rename.md)。

影响面：

- **Go module 与 import 路径**：`module notes` → `module seshat`；`notes/internal/...`、`notes/cmd/...` → `seshat/...`。
- **环境变量**：`NOTES_*` → `SESHAT_*`（`SESHAT_DB_KEY`、`SESHAT_AUTH_TOKEN`、`SESHAT_NODE_TOKEN`、`SESHAT_LLM_API_KEY`、`SESHAT_SERVER_URL`、`SESHAT_LOG_LEVEL`）；部署端的 `EnvironmentFile`、密钥注入脚本与 compose 环境变量键需同步改名。
- **数据路径**：`./data/notes.db` → `./data/seshat.db`、`./data/notes` → `./data/seshat`、`./data/notes/public` → `./data/seshat/public`；既有数据文件与目录（含笔记根内的 `.git/`）需迁移。
- **Elisp 包前缀**：`notes-*` → `seshat-*`（文件名与全部符号前缀）。
- **Android 包名**：`com.notes.app` → `com.seshat.app`；新包名等同于全新 App，**需卸载旧版后重装**并重新输入服务端地址与令牌。
- **systemd unit 与服务名**：`notes.service` → `seshat.service`；compose service / 容器名同步改名。
- **脚本产物名**：`notes-backup-*.tar.gz` / `notes-backup.log` → `seshat-backup-*`。
- **Web 管理界面**：内嵌前端（`internal/api/web/`）的品牌文案已更新；浏览器 `localStorage` 令牌键由 `notes.token` 改为 `seshat.token`，升级后**需在 Web 管理界面重新输入 API 令牌**。
- **客户端配置**：Elisp 变量前缀 `notes-*` → `seshat-*`，默认值更新（本地目录 `~/seshat`、远端目录 `"seshat"`、HEAD 文件 `~/.emacs.d/seshat-head`）；Android 加密配置文件名 `notes_sync_secure`/`notes_sync` → `seshat_sync_secure`/`seshat_sync`，**既有同步配置不会自动迁移，需重新配置**。

## [0.1.0] - 2026-10-11

首个版本。单用户、云 VPS 自托管的个人知识中枢，三端协作（Emacs 桌面端 / Android / 服务端）+ LLM 增值层。

### 新增

#### M0 — 项目脚手架与基础设施
- 初始化仓库结构：Go 模块、目录约定（`cmd/`、`internal/`、`docs/`、`openspec/`）、`.gitignore`、README 骨架。
- 配置管理：`config.yaml` + 环境变量覆盖，密钥/令牌仅从环境变量注入，不落盘、不进 git。
- 单用户认证：Bearer 令牌签发与校验中间件；WebDAV Basic Auth 复用同一令牌。
- 存储层：SQLite schema 迁移机制（当前为纯 Go 驱动 `modernc.org/sqlite`，密钥参数保留）。
- 结构化日志与统一错误包装骨架（含请求 ID）。
- 密钥管理：SQLCipher / LUKS / API 令牌的生成、注入（systemd EnvironmentFile）、权限、备份与恢复演练，见 `docs/security.md`。

#### M1 — 服务端核心
- WebDAV 服务（`golang.org/x/net/webdav`）：认证 + 范围限制（笔记目录 + 文件类型白名单）+ 内部/对外端点划分 + 写操作来源标记。
- git 版本化集成：写操作后自动 commit，ETag = 即时计算的 git blob hash，并发写串行化。
- 三方合并支持：merge-base + merge API，供客户端拉取共同祖先与最新版。
- REST API：阅读进度/批注 CRUD + `If-Modified-Since` 增量，见 `docs/api.md`、`docs/errors.md`。
- 附件内容寻址存储：SHA256 去重，对象库存 `files/objects/`，hash→路径映射存 DB，附件清单纳入 git。
- 全文索引：SQLite FTS5，org 变更后增量索引。

#### M2 — 桌面端 Emacs 插件
- WebDAV 客户端（基于 curl）：PROPFIND / GET / PUT 笔记目录。
- 冲突检测 + 三方合并：ETag / `If-Match` + `smerge-mode`。
- REST 状态同步：本地阅读进度/批注与服务端往返一致。
- 同步命令封装：单命令完成文件 + 状态同步，支持手动与定时触发。

#### M3 — Android 阅读器
- Kotlin 项目骨架 + WebDAV / REST 客户端。
- epub 阅读（Readium）+ 批注 + 进度持久化。
- pdf 阅读（MuPDF）+ 批注 + 进度持久化。
- 进度/批注 REST 往返同步。
- mobi 转 epub 导入（仅处理无 DRM 文件）。

#### M4 — Android GTD
- org 解析器：TODO 状态、优先级、tag、agenda。
- agenda / TODO 视图：状态、优先级、tag 过滤。
- 读写 org 文件 + WebDAV 同步，支持切换 TODO 状态后写回并同步。

#### M5 — 服务端管理与打磨
- 全文搜索接口 + 轻量单页 Web UI 管理界面。
- diff / revert / history 浏览。
- 对外 WebDAV 策略微调：读写/范围/扩展名白名单可按配置调整。
- VPS 数据备份策略：备份脚本 + 恢复演练，见 `scripts/backup.sh`、`docs/backup.md`。

#### M6 — LLM 增值层
- LLM 接入层：统一抽象 + 路由策略（云端 API / 本地处理节点，默认云端）。
- 本地处理节点 worker（Go）：轮询任务队列、本地 Ollama 推理、结果明文回传。
- 文档解析分析（PDF/EPUB 提取 + 结构化）。
- 笔记审查（错别字 / 失效链接 / 引用不一致）。
- 归纳总结（摘要 / 聚类）。
- 阅读行为分析（阅读画像与建议）。
- 遗忘性复习（SM-2 间隔重复 + 复习卡片）。

### 技术债

已知技术债详见 [openspec/tech-debt.md](openspec/tech-debt.md)，当前 7 条**均已解决或明确分工**（历史记录保留）：

1. SQLCipher 降级——**已解决**：`internal/storage` 改为 build tag 双驱动，`-tags "sqlcipher sqlite_fts5"` 启用加密（go-sqlcipher 自带 amalgamation，无需系统 libsqlcipher），无该 tag 为明文 + LUKS 兜底（M0.4）。
2. LLM 双后端未打通——**已明确分工**：同步直连（`LocalNodeClient`）与异步任务队列（`llm_tasks` + `cmd/llmnode`）界定边界与选择依据，契约见 `docs/llm.md`（M6）。
3. REST 状态同步缺时间戳冲突检测——**已解决**：`SetProgress`/`UpdateAnnotation` 增加乐观冲突检测，客户端 `updated_at` 早于服务端记录时返回 409 且不覆盖（M1.4）。
4. 单令牌无角色区分——**已解决**：引入独立节点令牌 `NOTES_NODE_TOKEN`，节点端点经 `auth.NodeMiddleware` 校验，实现节点与主令牌的最小权限隔离。
5. Android 令牌明文存 SharedPreferences——**已解决**：改用 `EncryptedSharedPreferences`（Android Keystore 主密钥，`androidx.security:security-crypto`）。
6. elisp 令牌经 curl 命令行传递——**已解决**：改用 `curl --config`（0600 权限临时配置文件），令牌不再出现在命令行与进程列表。
7. 部署即明文风险——**已解决**：`docs/deploy.md` 将数据盘 LUKS 加密设为硬性步骤并纳入部署检查清单。
