# Notes — 个人笔记同步系统

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
- 实施计划：openspec/active/personal-notes-system.md
- 决策日志：openspec/decisions.md
- ADR：docs/adr/

## 快速开始
（待 M0 里程碑完成后补充）
