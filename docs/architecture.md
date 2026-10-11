# 架构设计

## 概述

个人笔记同步系统是单用户、云 VPS 自托管的个人知识中枢，三端协作 + LLM 增值：

- 桌面端 Emacs（org-mode）负责笔记编辑，文件同步复用 org-mode 设施
- Android 端负责电子书阅读/批注（epub/pdf，mobi 转 epub）与 org GTD 查看
- 服务端统一汇总文件、附件与三端阅读状态，提供 WebDAV、REST、git 版本化、静态加密、全文索引与 LLM 能力

## 核心决策（P0，用户确认）

1. 加密语义：静态加密（SQLCipher + 磁盘 LUKS，服务端可读明文做索引）
2. 技术栈：服务端 Go、Android Kotlin 原生、桌面端 elisp
3. 部署：云 VPS
4. WebDAV：双重定位（内部同步通道 + 对外标准出口）
5. 访问控制：单用户（Bearer 令牌 + WebDAV Basic Auth 同令牌）
6. 冲突处理：服务端 git 版本化 + ETag 乐观锁 + 自有客户端三方合并（ADR-001）
7. 对外 WebDAV：可读写 + 范围受限（笔记目录 + 文件类型白名单）+ 每次写自动 commit
8. LLM 后端：混合（云端 API + 本地处理节点），本地节点为纯推理节点、结果明文回传，无 E2EE（ADR-002）

## 模块划分（服务端）

- cmd/server：入口
- internal/config：配置加载（config.yaml + 环境变量覆盖）
- internal/auth：单用户认证
- internal/storage：SQLite(SQLCipher) + 文件系统 + git 版本库
- internal/logging：结构化日志
- internal/webdav：WebDAV 服务（后续里程碑）
- internal/api：REST API（后续里程碑）
- internal/index：全文索引 FTS5（后续里程碑）
- internal/llm：LLM 接入层（后续里程碑）

## 同步协议

- 文件（org/附件/电子书）→ WebDAV，ETag 乐观锁
- 状态（阅读进度/批注）→ REST，后写覆盖 + 时间戳冲突检测
- 附件（二进制）→ 内容寻址存储（SHA256）+ 「附件清单」文件纳入 git

## 数据流

- 桌面端/Android 经 WebDAV 同步文件，经 REST 同步阅读进度/批注
- 服务端 WebDAV 写操作后自动 git commit（记录来源），ETag 用工作区内容即时 blob hash
- 敏感/需本地模型任务经任务队列路由到本地处理节点，结果明文回传服务端
