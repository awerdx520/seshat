# Seshat — 个人笔记同步系统

单用户、云 VPS 自托管的个人知识中枢，三端协作 + LLM 增值。

## 三端
- **桌面端**：Emacs（org-mode）+ 同步插件，复用 org-mode
- **Android 端**：Kotlin 单 App 双模块（① 电子书阅读/批注 ② org GTD）
- **服务端**：Go（WebDAV + REST + git 版本化 + 静态加密 + FTS5 + LLM 增值）

## 核心特性
- WebDAV 文件同步（内部通道 + 对外标准出口）
- git 版本化 + ETag 乐观锁 + 三方合并（多端冲突不丢数据）
- 静态加密存储 + 全文索引
- LLM 混合后端（云端 API + 本地处理节点）

## 文档
- 架构设计：docs/architecture.md
- Emacs 阅读器使用手册：[docs/emacs-reader.md](docs/emacs-reader.md)
- 实施计划：openspec/completed/personal-notes-system.md
- 决策日志：openspec/decisions.md
- ADR：docs/adr/

## 开发
- 克隆后先安装提交前钩子（密钥扫描，详见 docs/security.md §6）：`pre-commit install`
- 钩子全量运行：`pre-commit run --all-files`；但 gitleaks 只扫暂存区，需全量/历史内容检查时见 docs/security.md §6.3

## 快速开始
- 生成密钥：`scripts/gen-secrets.sh`（输出 `./data/secrets.env`，权限 600）
- 部署与启动：见 docs/deploy.md
