# 个人笔记同步系统 — 实施计划

## 当前状态
- 阶段：Phase 3（Implement）· 进行中
- 已确认：方案 ✅、计划 ✅（用户 2026-10-11 确认）
- 次级决策：已确认（mobi 转 epub、Android 单 App 双 Tab、FTS5 索引、LLM 路由默认云端、M5.1 管理界面 Web UI）
- 下一步：从 M0 里程碑开始实施

## 目标

构建单用户、云 VPS 自托管的个人知识中枢，三端协作 + LLM 增值：
- **桌面端**（Emacs + org-mode）：文件同步 + 阅读进度/批注状态同步，完全复用 org-mode
- **Android 端**（Kotlin 单 App 双模块）：① 电子书阅读/批注（epub/pdf，mobi 转 epub 导入）② org GTD 查看（类 orgzly）
- **服务端**（Go）：WebDAV（文件）+ REST（状态）+ git 版本化 + 静态加密 + 全文索引 + 二进制附件 + LLM 增值层
- **LLM 增值层**：文档解析分析、笔记错误/引用审查、阅读行为分析、遗忘性复习（间隔重复）、归纳总结

## 设计（已确认决策）

### P0 决策（用户显式确认）
1. 加密语义：**静态加密**（SQLCipher + 磁盘 LUKS，服务端可读明文做索引）
2. 技术栈：服务端 **Go**，Android **Kotlin** 原生，桌面端 **elisp**
3. 部署：**云 VPS**
4. WebDAV：**双重定位**（内部文件同步通道 + 对外标准出口）
5. 访问控制：**单用户**（Bearer 令牌 + WebDAV Basic Auth 同令牌）
6. 冲突处理：**服务端 git 版本化 + ETag 乐观锁 + 自有客户端三方合并**（详见 docs/adr/0001-git-versioning-conflict-resolution.md）
7. 对外 WebDAV：**可读写 + 范围受限（仅暴露笔记目录）+ 每次写自动 commit**
8. LLM 后端：**混合（本地 Ollama + 云端 API）**，敏感笔记走本地、复杂任务走云端

### 次级决策（已确认）
- mobi 处理：转 epub 导入，不原生渲染（Readium/MuPDF 均不支持 mobi）
- Android 结构：单 App 双 Tab（阅读器 + GTD）
- 索引引擎：SQLite FTS5
- LLM 路由：默认云端 API，需本地模型的任务（隐私敏感/本地模型擅长）走本地处理节点
- M5.1 管理界面：Web UI（轻量单页）

### 同步协议
- 文件（org/附件/电子书）→ WebDAV，ETag 乐观锁
- 状态（阅读进度/批注）→ REST，后写覆盖 + 时间戳冲突检测
- 附件（二进制）→ 内容寻址存储（SHA256）+ 「附件清单」文件纳入 git

### LLM 路由策略
- 云端 API（DeepSeek）：VPS 直接调用，处理一般/复杂任务
- 本地处理节点（家庭机器/NAS 跑 Ollama）：通过任务队列接收任务 → 本地推理 → 结果明文回传服务端
- 统一 LLM 抽象层，路由规则可配置，默认云端
- 所有数据统一静态加密（服务端可读明文），无 E2EE

### LLM 任务队列与节点协议
- 任务队列：SQLite 表（llm_tasks），字段含 id/类型/payload/路由目标(cloud|local)/状态/结果/时间戳
- 节点注册：本地节点启动时用节点令牌（环境变量注入）向服务端注册，记录节点在线状态
- 通信协议：本地节点 HTTPS 长轮询 `GET /api/llm/tasks/poll` 拉取 pending 任务 → 本地 Ollama 推理 → `POST /api/llm/tasks/{id}/result` 回传结果
- 节点认证：Bearer 节点令牌（复用单用户认证体系）
- 路由判定：任务默认云端；标记 `route=local` 的任务走本地节点；规则可配置
- 传输安全：全链路 TLS；本地节点建议经 VPN 或仅凭令牌 + TLS 访问
- worker 技术栈：Go（与服务端一致，复用认证/HTTP 客户端代码）

## 任务

### 里程碑 M0：项目脚手架与基础设施
- [ ] M0.1 初始化仓库结构：Go 模块、目录约定（cmd/、internal/、docs/、openspec/）、.gitignore、README.md 骨架
  - 验收：`go build ./...` 通过；目录结构符合约定
  - 依赖：无
- [ ] M0.2 配置管理：密钥/令牌从环境变量注入，配置加载（config.yaml + 环境变量覆盖）
  - 验收：配置加载单测通过；敏感值不落盘、不进入 git；`docs/configuration.md` 列出全部配置项
  - 依赖：M0.1
- [ ] M0.3 单用户认证：Bearer 令牌签发与校验中间件
  - 验收：认证中间件单测（正确/错误/缺失令牌）；WebDAV Basic Auth 复用同一令牌
  - 依赖：M0.2
- [ ] M0.4 存储层初始化：SQLite + SQLCipher，schema 迁移机制
  - 验收：数据库加密创建成功；迁移脚本可执行；`go test ./...` 通过
  - 依赖：M0.1
- [ ] M0.5 日志与错误处理骨架
  - 验收：结构化日志（含请求 ID）输出；错误统一包装
  - 依赖：M0.1
- [ ] M0.6 密钥管理：SQLCipher 密钥、LUKS 密钥、API 令牌的生成、注入（systemd EnvironmentFile/密钥文件）、权限、备份、恢复演练
  - 验收：密钥可安全注入且重启后服务自动可用；备份/恢复演练文档齐全；`docs/security.md` 密钥管理专节完成
  - 依赖：M0.2, M0.4

### 里程碑 M1：服务端核心
- [ ] M1.1 WebDAV 服务：golang.org/x/net/webdav，挂载笔记目录，认证 + 范围限制（精确到「笔记目录 + 文件类型白名单」）+ 内部/对外端点划分 + 写操作来源标记
  - 验收：PROPFIND/GET/PUT/DELETE 可用；无法访问 .git/、配置、附件原始库；对外端点仅暴露笔记目录；写操作来源标记（自有客户端/外部应用）可区分
  - 依赖：M0.3
- [ ] M1.2 git 版本化集成：libgit2，写操作后自动 commit，ETag = 工作区当前内容即时计算的 git blob hash（`sha1("blob <size>\0<content>")`），并发写串行化（服务端写锁）
  - 验收：PUT 后自动 commit；ETag 稳定且与 commit 时序解耦；并发 PUT 不产生损坏 commit、不丢数据；历史可遍历
  - 依赖：M1.1
- [ ] M1.3 三方合并支持：merge-base + merge API，供自有客户端拉取共同祖先与最新版
  - 验收：可获取 merge-base；模拟冲突场景能返回共同祖先 + 最新版
  - 依赖：M1.2
- [ ] M1.4 REST API：阅读进度/批注 CRUD + If-Modified-Since 增量；产出 docs/api.md 与 docs/errors.md
  - 验收：API 单测 + 集成测试通过；docs/api.md 覆盖全部端点、docs/errors.md 覆盖错误码
  - 依赖：M0.3, M0.4
- [ ] M1.5 附件内容寻址存储：SHA256 去重，附件存独立对象库（files/objects/），hash→路径映射存 SQLCipher DB，「附件清单」文件纳入 git
  - 验收：重复附件只存一份；清单变更可 git 追溯；hash 映射可查询
  - 依赖：M1.2
- [ ] M1.6 全文索引：SQLite FTS5，org 变更后增量索引（变更入口 = WebDAV 写入）
  - 验收：全文搜索命中 org 内容；增量索引正确反映最新内容
  - 依赖：M1.1, M1.2, M0.4

### 里程碑 M2：桌面端 Emacs 插件
- [ ] M2.1 WebDAV 客户端（文件拉取/推送，复用 tramp 或 curl）
  - 验收：elisp 包可 PROPFIND/GET/PUT 笔记目录；PUT 后远端内容与本地一致（curl 校验）；check-parens 通过
  - 依赖：M1.1
- [ ] M2.2 冲突检测 + 三方合并（ETag/If-Match + smerge-mode）
  - 验收：模拟远端变更时，本地检测到 412 并调出三方合并（smerge）；合并后正确提交
  - 依赖：M1.3, M2.1
- [ ] M2.3 REST 状态同步（进度/批注）
  - 验收：本地进度/批注可推送至服务端并从服务端拉取（往返一致）
  - 依赖：M1.4
- [ ] M2.4 同步命令封装（手动 + 定时）
  - 验收：单命令完成文件+状态同步；定时触发可用；冲突自动进入合并流程
  - 依赖：M2.1, M2.2, M2.3

### 里程碑 M3：Android 阅读器
- [ ] M3.1 Kotlin 项目骨架 + WebDAV/REST 客户端
  - 验收：项目可编译；WebDAV PROPFIND/GET/PUT、REST CRUD 单测通过
  - 依赖：M1.1, M1.4
- [ ] M3.2 epub 阅读（Readium）+ 批注 + 进度
  - 验收：可打开 epub、翻页、添加批注、记录进度（设备内持久化）
  - 依赖：M3.1
- [ ] M3.3 pdf 阅读（MuPDF）+ 批注 + 进度
  - 验收：可打开 pdf、翻页、批注、进度持久化
  - 依赖：M3.1
- [ ] M3.4 进度/批注 REST 同步
  - 验收：阅读器进度/批注与 M1.4 服务端往返同步一致
  - 依赖：M1.4, M3.2, M3.3
- [ ] M3.5 mobi 转 epub 导入
  - 验收：mobi 文件可转 epub 并导入阅读器（无 DRM 文件）
  - 依赖：M3.1

### 里程碑 M4：Android GTD
- [ ] M4.1 org 解析器（TODO/agenda/tag/优先级）
  - 验收：给定含 TODO/优先级/tag 的 org 样例，解析出对应结构化结果，单测覆盖
  - 依赖：无（纯解析，可独立）
- [ ] M4.2 agenda/TODO 视图
  - 验收：展示 agenda 列表、TODO 状态、优先级、tag 过滤
  - 依赖：M4.1
- [ ] M4.3 读写 org 文件 + WebDAV 同步
  - 验收：修改 TODO 状态后写回 org 文件并经 WebDAV 同步到服务端
  - 依赖：M1.1, M4.1

### 里程碑 M5：服务端管理/整理 + 打磨
- [ ] M5.1 全文搜索接口 + 管理界面（Web UI 轻量单页）
  - 验收：搜索接口可命中笔记；管理界面（形态确认后）可用
  - 依赖：M1.6
- [ ] M5.2 diff/revert/history 浏览
  - 验收：可浏览文件历史、查看 diff、revert 到历史版本
  - 依赖：M1.2
- [ ] M5.3 对外 WebDAV 策略微调
  - 验收：对外出口的读写/范围/白名单策略可按配置调整（安全边界已在 M1.1 定义）
  - 依赖：M1.1
- [ ] M5.4 VPS 数据备份策略
  - 验收：备份脚本 + 恢复演练通过（与 M0.6 密钥备份联动）
  - 依赖：M0.6

### 里程碑 M6：LLM 增值层
- [ ] M6.1 LLM 接入层（统一抽象 + 路由策略：云端 API / 本地处理节点）
  - 验收：统一接口可调用云端 API 与本地节点；路由规则按配置生效（默认云端）
  - 依赖：M0.2
- [ ] M6.2 本地处理节点 worker（Go，家庭机器/NAS 跑 Ollama，轮询任务队列、本地推理、结果明文回传）
  - 验收：节点可注册、拉取任务、回传结果；结果明文存服务端（静态加密）
  - 依赖：M6.1, M0.3, M0.4
- [ ] M6.3 文档解析分析（PDF/EPUB 提取 + 结构化）
  - 验收：上传 PDF/EPUB 可提取文本并结构化（标题/段落/术语/实体）
  - 依赖：M6.1
- [ ] M6.4 笔记审查（错误/引用）
  - 验收：对 org 笔记执行审查，输出错别字/失效链接/引用不一致报告
  - 依赖：M6.1
- [ ] M6.5 归纳总结（摘要/聚类）
  - 验收：长文档/笔记集生成摘要与聚类标签
  - 依赖：M6.1
- [ ] M6.6 阅读行为分析
  - 验收：从进度/批注数据生成阅读画像与建议
  - 依赖：M6.1, M1.4
- [ ] M6.7 遗忘性复习（SM-2 间隔重复 + 复习卡片）
  - 验收：复习卡片生成、SM-2 调度、到期提醒
  - 依赖：M6.1

## 文档清单

| 文档 | 用途 | 负责任务 | 状态 |
|---|---|---|---|
| README.md | 项目入口 | M0.1 | 待建 |
| docs/architecture.md | 架构设计 | M0.1 | 待建 |
| docs/api.md | REST API 规范 | M1.4 | 待建 |
| docs/errors.md | 错误码规范 | M1.4 | 待建 |
| docs/configuration.md | 配置项说明 | M0.2 | 待建 |
| docs/sync-protocol.md | 同步协议 | M1.1 | 待建 |
| docs/security.md | 加密、认证、密钥管理 | M0.6 | 待建 |
| docs/org-format.md | org 解析约定 | M4.1 | 待建 |
| docs/llm.md | LLM 路由与模型约定 | M6.1 | 待建 |
| CHANGELOG.md | 变更历史 | 各里程碑 | 待建 |

## 验证标准

- L1：Go `go build ./...` + `go vet ./...`；elisp `check-parens`（经 emacsclient）；Kotlin `./gradlew assembleDebug`
- L2：`go test ./...`（认证、WebDAV、git 版本化、REST、索引、密钥）；Android `./gradlew test`
- L3：端到端场景（桌面端↔服务端↔Android 同步往返、冲突三方合并、外部应用覆盖后历史恢复、LLM 路由生效）

## 注意事项

1. **外部应用兼容性**：WebDAV 必须严格遵循 RFC 4918（PROPFIND/ETag/If-Match），否则第三方客户端无法正常工作。
2. **git 自动 commit 治理**：高频写入会产生大量 commit，需设计 commit 合并策略（按会话/时间窗口合并）与 `git gc` 周期。
3. **并发写串行化**：libgit2 的 index.lock 竞态，需服务端写锁/队列串行化所有写操作，防止损坏 commit。
4. **敏感数据**：密钥/令牌仅环境变量注入，禁止落盘或进入 git；`.gitignore` 排除密钥文件与 .env。
5. **密钥生命周期**：静态加密下丢失密钥 = 数据永久丢失，密钥备份与恢复演练是硬性要求（M0.6）。
6. **附件不进 git**：二进制附件走内容寻址对象库，避免 git 仓库膨胀。
7. **范围限制安全**：对外 WebDAV 必须严格限制在笔记目录 + 文件类型白名单，禁止访问 .git/、配置、附件原始库。
8. **LLM 路由与隐私**：云端 API 调用仅发送任务相关最小片段；需本地模型的任务走本地处理节点；所有数据统一静态加密。
9. **mobi 版权/转换**：mobi 转 epub 需注意 DRM 限制，仅处理无 DRM 文件。
10. **org 解析兼容性**：org 方言众多，GTD 解析需覆盖常见 TODO 状态、优先级、tag、agenda 文件。
