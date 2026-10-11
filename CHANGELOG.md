# Changelog

本项目所有值得注意的变更记录于此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

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

已知技术债与待办详见 [openspec/tech-debt.md](openspec/tech-debt.md)，当前 7 条：

1. SQLCipher 降级——系统未装 libsqlcipher，DB 层暂用无加密驱动，兜底依赖磁盘 LUKS（M0.4）。
2. LLM 双后端未打通——`LocalNodeClient` 直连 Ollama 与任务队列轮询是两套机制（M6）。
3. REST 状态同步缺时间戳冲突检测——`SetProgress`/`UpdateAnnotation` 为纯后写覆盖（M1.4）。
4. 单令牌无角色区分——LLM 节点复用同一令牌，poll/result 端点无节点身份绑定。
5. Android 令牌明文存 SharedPreferences——待改用 EncryptedSharedPreferences。
6. elisp 令牌经 curl 命令行传递——令牌短暂暴露于进程列表，待改用 `--netrc-file` / `--config`。
7. 部署即明文风险——SQLCipher 降级下若未启用 LUKS，数据明文落盘，需在部署清单设为硬性步骤。
