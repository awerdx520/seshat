# Seshat — 个人笔记系统（客户端仓）

> 本仓只含客户端（Emacs + Android）；服务端已迁至 **keystone** 仓，见 [`docs/SERVER-CONTRACT.md`](docs/SERVER-CONTRACT.md)。

单用户、云 VPS 自托管的个人知识中枢；客户端双端协作，服务端能力（WebDAV + REST + git 版本化 + 静态加密 + FTS5 + LLM 增值）由 keystone 提供。

## 两端
- **桌面端**：Emacs（**32.0+**，阅读器渲染后端使用 Emacs 32 的 canvas 图像对象）+ 同步插件，复用 org-mode
- **Android 端**：Kotlin 单 App 双模块（① 电子书阅读/批注 ② org GTD）

## 核心特性
- WebDAV 文件同步（内部通道 + 对外标准出口）
- git 版本化 + ETag 乐观锁 + 三方合并（多端冲突不丢数据）
- 阅读器：epub/pdf 渲染、批注、跨页选择、目录、主题与手写
- LLM 增值（云端 API 与本地处理节点由服务端侧承载）

## 文档
- 服务端契约与迁移边界：[docs/SERVER-CONTRACT.md](docs/SERVER-CONTRACT.md)
- Emacs 阅读器使用手册（安装与加载见 §2）：[docs/emacs-reader.md](docs/emacs-reader.md)
- Android 客户端结构与构建：[docs/android.md](docs/android.md)
- 阅读器面板载体决策：[docs/adr/0005-reader-panel-carrier.md](docs/adr/0005-reader-panel-carrier.md)
- 实施计划：openspec/completed/personal-notes-system.md
- 决策日志：openspec/decisions.md
- 路线图：openspec/roadmap.md
- 技术债：openspec/tech-debt.md

## 开发
- 克隆后先安装提交前钩子（密钥扫描）：`pre-commit install`
- 钩子全量运行：`pre-commit run --all-files`（gitleaks 只扫暂存区，需全量/历史内容检查时直接跑 `gitleaks git`）
- Emacs 端 ERT 测试：`make -C emacs/tests ert`（入口与判据见 `emacs/tests/README.md`）

## 快速开始（客户端）
- Emacs：按 [docs/emacs-reader.md](docs/emacs-reader.md) §2 安装与加载，§3 起为阅读操作
- Android：构建与验证命令见 [docs/android.md](docs/android.md)
- 连接服务端：客户端配置变量（`seshat-sync-*`、`seshat-rest-*`、`seshat-reader-*`）不变；部署与运维见 keystone 仓
