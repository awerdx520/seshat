# Seshat 路线图（M7–M11）：资源 ID · 引用 · 增量同步

## 当前状态

- 阶段：Phase 2（Plan）· 路线图已落盘
- 已确认：整体方案 ✅（用户 2026-10-12 确认）、路线图 ✅（用户 2026-10-12 确认）
- 加密：维持现有 TLS（反向代理终止）；**不做应用层加密**（用户已取消该需求）
- 下一步：等待用户指示是否开工 M7（M7 需另行走方案确认与计划确认两道门禁）
- 未决问题（阻塞后续里程碑，不阻塞本文件）：收录目录清单、GTD 深度、Reader 功能清单、EPUB location 约定

## 背景与起点

M0–M6 已完成并归档，见 `openspec/completed/personal-notes-system.md`。本路线图续编 M7 起。

### 已有资产（M0–M6，保留或改造）

| 已有 | 与新路线的关系 |
|---|---|
| WebDAV + git 版本化 + ETag + 三方合并 | 保留；M7 后 WebDAV 退居「第三方侧门」 |
| REST 进度/批注（M1.4）+ 三端往返（M2.3/M3.4） | 改造：`document_id` → `uid` |
| 附件内容寻址（M1.5）、FTS5（M1.6） | 复用（blob 通道） |
| Emacs WebDAV 同步器（M2.1–M2.4） | 重构为 REST（M8，最大返工点） |
| Android epub/pdf 阅读 + 批注 + GTD 雏形（M3/M4） | 改造：UI 重构 + uid 接入 |

### 已确认的关键决策

| # | 决策 | 状态 |
|---|---|---|
| 1 | `document_id` 统一收敛为 `uid`（含存量迁移） | 用户确认 |
| 2 | 同步模型 = 增量 | 用户确认 |
| 3 | Emacs rename = 同步器快照比对、用户无感 | 用户确认 |
| 4 | 收录范围 = 指定目录全部（多根 + 逻辑前缀） | 用户确认 |
| 5 | 传输：笔记全量镜像；电子书/附件按需 | 用户确认 |
| 6 | 批注 = 侧车（不写回 PDF），存服务端 | 用户确认 |
| 7 | 生态内 REST；WebDAV 仅第三方 | 用户确认 |
| 8 | 服务端权威，本地映射为派生状态 | 用户确认 |
| 9 | 传输加密维持现有 TLS；不做应用层加密 | 用户确认 |

## 根本问题与假设

**根本问题**：三端要围绕同一批文件与批注协作，但当前文件身份 = 路径（会变、且各端路径空间不同），导致批注/进度/引用无法稳定锚定。同时有三个硬约束：Emacs 生态要求零侵入、第三方要求标准出口、自有端要求高效增量。

**假设清单**：

| # | 假设 | 来源 |
|---|---|---|
| A1 | 服务端是唯一权威，本地只是物化镜像 | 用户显式 |
| A2 | 客户端集合 = Emacs + Android（PC 端需求已取消） | 用户显式 |
| A3 | 笔记体量适合全量镜像（org 文本，MB 级） | 假设? |
| A4 | 增量采用「全局 change_seq + 客户端游标」日志模型 | 类比⚡（Syncthing/Dropbox journal） |
| A5 | Emacs 的 denote/org 包不可感知系统，集成必须外挂 | 用户显式 |
| A6 | 冲突沿用现有 ETag 乐观锁 + 三方合并 | 假设?（复用既有资产） |

## 里程碑总览

| 里程碑 | 主题 | 依赖 | 规模 | 风险 |
|---|---|---|---|---|
| M7 | 服务端地基：`uid` + 引用 + 增量同步 | — | 大 | 中（迁移） |
| M8 | Emacs 端接入（REST 同步器 + 状态库 + 透明集成） | M7 | 大 | 高（返工现有完工代码） |
| M9 | Android 三区 UI 重构 + Notes/GTD | M7 | 大 | 中 |
| M10 | Android Reader（书架 + 阅读增强 + 批注侧车） | M7、M9 | 中 | 中 |
| M11 | 批注与引用闭环（Emacs 阅读批注 + 双向引用） | M8、M10 | 中 | 高（需改 emacs-reader） |

**关键路径**：`M7 → M8 → M11`；`M7 → M9 → M10` 可与 M8 并行。

## 里程碑明细

### M7 服务端地基（uid + 引用 + 增量）

| 子项 | 内容 | 验收要点 |
|---|---|---|
| M7.1 | `resources` / `changes` / `refs` 三表 + 迁移（`document_id` → `uid`） | 迁移可重跑；存量 progress/annotations 成功映射 uid |
| M7.2 | 根映射配置（多根 + 逻辑前缀），服务端权威、可下发 | 多根同名文件不冲突 |
| M7.3 | REST：`files` CRUD/move、`changes`（since 游标）、`resolve`、`refs` | curl 走通「增→改→重命名→删→增量拉取」，uid 全程稳定 |
| M7.4 | WebDAV 写路径登记钩子（第三方写入同样进 registry） | 第三方 PUT/MOVE 后能在 `resources` 查到 |
| M7.5 | 协议文档重写（`docs/sync-protocol.md`、`docs/api.md`） | 新人可据文档实现一个客户端 |
| M7.6 | `seshat:` 引用语法 + 解析 | 链接可解析为 uid（跨端一致） |

### M8 Emacs 端接入

| 子项 | 内容 | 风险 |
|---|---|---|
| M8.1 | REST 同步器（替代 WebDAV 传输层） | 高：现有 `emacs/notes-sync.el` 返工 |
| M8.2 | 本地状态库（`uid↔path`、`base_revision`、`cursor`、dirty、墓碑） | 中 |
| M8.3 | 快照比对 → rename/move 检测上报（用户无感） | 中 |
| M8.4 | 根映射支持（多根 + 前缀） | 低 |
| M8.5 | `seshat:` org-link follow（uid → 本地路径） | 低 |
| M8.6 | 透明性验证：denote/dired/org-agenda 行为零变化 | 高（零侵入约束） |

### M9 Android 客户端重构

| 子项 | 内容 |
|---|---|
| M9.1 | 三区 UI 骨架（工具栏 / 内容区 / 底部 Notes·Reader 双 tab）+ 设置页 |
| M9.2 | 数据源接入（uid + 增量 + 本地缓存 + 按需下载电子书） |
| M9.3 | Notes：orgzly 风格列表 / 搜索 / 展开 / 编辑 |
| M9.4 | GTD：agenda 视图增强（M4 基础上） |

### M10 Android Reader

| 子项 | 内容 |
|---|---|
| M10.1 | 书架（元数据来自服务端，封面/进度/按需下载） |
| M10.2 | 阅读增强（目录/主题/字体/跳转） |
| M10.3 | 批注侧车 + `location` 约定统一（PDF `page:<n>`+范围；EPUB 待定） |
| M10.4 | 进度/批注 uid 化同步 |

### M11 批注与引用闭环

| 子项 | 内容 | 备注 |
|---|---|---|
| M11.1 | emacs-reader 文本提取（C 模块扩展） | ✅ PoC 通过（2026-10-12）；见 notes/openspec/active/2026-10-12-m11.1-emacs-reader-text-poc.md |
| M11.2a | vendor reader 源码，建 seshat-reader 包 | ✅ vendor 与验证完成（2026-10-12），配置切换已完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-seshat-reader-vendor.md |
| M11.2b | 阅读器鼠标选区取文（Phase 1） | ✅ 完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-m11.2b-reader-selection.md |
| M11.2c | seshat-reader 包彻底自研化改名（feature/符号/文件名/C 模块名统一 seshat-reader-*） | ✅ 完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-m11.2c-seshat-reader-rename.md |
| M11.3 | Emacs 侧批注采集 + 侧车同步 | ✅ 完成（2026-10-16；L3 端到端待服务端可用时补验）；见 openspec/completed/2026-10-16-m11.3-reader-annotations.md |
| M11.4 | 双向引用（笔记 ↔ 批注/书籍） | |
| M11.5 | 阅读器翻译/解释（go-translate + posframe） | ✅ 完成（2026-10-16）；见 openspec/completed/2026-10-16-m11.5-reader-translate.md |
| M11.6 | 批注离线优先 + 自动同步（本地队列、幂等去重、自动推进） | ✅ 完成（2026-10-16）；见 openspec/completed/2026-10-16-m11.6-annotation-offline.md |

## 风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | Emacs 同步器 WebDAV→REST 重写 | 已有完工功能回退 | 保留 WebDAV 兼容路径做灰度；先并行双跑再切换 |
| R2 | 改 emacs-reader（第三方包，pin 在 commit） | 维护成本、上游不接受 LLM 贡献 | M11.1 可独立/可放弃，先只做「进度」再评估批注 |
| R3 | `document_id`→`uid` 迁移 | 存量数据、Android prefs、Emacs 配置 | 按 `openspec/decisions.md`「C 数据契约域」纪律（复制 + 观察期） |
| R4 | Android UI 重构范围大 | 工期 | 与 M7 并行，先出静态骨架 |
| R5 | 未决范围（见下） | 返工 | 在对应里程碑开工前澄清 |

## 未决问题

1. 收录目录清单（哪些根、什么前缀）—— M7.2 需要
2. GTD 深度（只读 / 可编辑 / repeater·DEADLINE·状态流转）—— M9.4 需要
3. Reader「基础功能」清单（排除 TTS/词典/统计？）—— M10 需要
4. EPUB 的 location 约定（CFI vs `chapter:x`）—— M10.3 需要

## 文档清单

| 文档 | 用途 | 涉及里程碑 |
|---|---|---|
| docs/sync-protocol.md | 同步协议（重写） | M7.5 |
| docs/api.md | REST API 规范（新增 files/changes/resolve/refs） | M7.3 |
| docs/configuration.md | 根映射配置 | M7.2 |
| docs/architecture.md | 架构设计（同步章节重写） | M7.5 |
| docs/adr/ | uid 化、增量同步（两篇 ADR） | M7 |
| openspec/decisions.md | 决策日志 | 全程 |
| CHANGELOG.md | 变更历史 | 全程 |
