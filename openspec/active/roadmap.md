# Seshat 路线图（M7–M11）：资源 ID · 引用 · 增量同步

## 当前状态

- 阶段：Phase 4（Review & Document）· M7 已完成并归档
- 已确认：整体方案 ✅（用户 2026-10-12 确认）、路线图 ✅（用户 2026-10-12 确认）；M7 方案 ✅ 与计划 ✅（用户 2026-10-18 确认）
- 加密：维持现有 TLS（反向代理终止）；**不做应用层加密**（用户已取消该需求）
- 下一步：M8（Emacs 端接入）需另行方案确认与计划确认
- 2026-10-18 进展：M9.1 / M9.2（设置项·连续滚动）/ M10.5（手写·点击翻页·横屏）/ M10.6-B1（服务端可选）已完成并归档；M10.6-B2（阅读器交互：浮层显隐·SeekBar·目录）、M10.6-B3（书架：封面网格·进度徽标·过滤排序·点击打开）、M10.6-B4（Notes：树列表·搜索·编辑页·GTD 并入 + `NotesSync` 抽取与数据源统一）与 M10.7（笔记库：多文件列表·org/md 渲染阅读·文件级源码编辑·SAF 外部目录）代码/单测/文档完成（真机待验，设备锁屏）；M7 服务端已完成（待提交）；下一步为**真机验收（B2/B3/B4/M10.7）→ 计划归档**
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

计划与执行记录：[openspec/completed/2026-10-18-m7-uid-identity-and-incremental-sync.md](../completed/2026-10-18-m7-uid-identity-and-incremental-sync.md)（已完成并归档，2026-10-18）。**M7.1 的验收要点据实调整**：因服务端尚未部署、无存量数据，迁移拆为 v6（只建身份三表）与 v7（`DROP` 重建状态表，`preMigrationChecks[7]` 以 `COUNT(*)` 非空即中止为防御），不做 `document_id` → uid 的存量映射（见 `openspec/decisions.md` 2026-10-18）。

| 子项 | 内容 | 验收要点 |
|---|---|---|
| M7.1 | `resources` / `changes` / `refs` 三表 + 迁移（`document_id` → `uid`） | 迁移可重跑；存量 progress/annotations 成功映射 uid —— ✅ 完成（2026-10-18；迁移可重跑已验证，存量映射改为 v6/v7 拆分 + 非空即中止） |
| M7.2 | 根映射配置（多根 + 逻辑前缀），服务端权威、可下发 | 多根同名文件不冲突 —— ✅ 完成（2026-10-18） |
| M7.3 | REST：`files` CRUD/move、`changes`（since 游标）、`resolve`、`refs` | curl 走通「增→改→重命名→删→增量拉取」，uid 全程稳定 —— ✅ 完成（2026-10-18） |
| M7.4 | WebDAV 写路径登记钩子（第三方写入同样进 registry） | 第三方 PUT/MOVE 后能在 `resources` 查到 —— ✅ 完成（2026-10-18；含启动全量登记 `Bootstrap`） |
| M7.5 | 协议文档重写（`docs/sync-protocol.md`、`docs/api.md`） | 新人可据文档实现一个客户端 —— ✅ 完成（2026-10-18） |
| M7.6 | `seshat:` 引用语法 + 解析 | 链接可解析为 uid（跨端一致） —— ✅ 完成（2026-10-18；服务端 `refs` 支持 `tag:path` 与 uid 双形态） |

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
| M9.1 | 三区 UI 骨架（工具栏 / 内容区 / 底部 Notes·Reader 双 tab）+ 设置页 ✅ 完成（2026-10-18），见 openspec/completed/2026-10-18-m9.1-android-shell.md |
| M9.2 | 数据源接入（uid + 增量 + 本地缓存 + 按需下载电子书）——A 批（Android 接 M7：uid 化 + 只读协议 + 索引 + 增量 + 阅读器 uid 接入）✅ 完成（2026-10-18），见 openspec/completed/2026-10-18-m9.2-android-m7-client.md；B 批（文件同步，支撑书架）待做 |
| M9.3 | Notes：orgzly 风格列表 / 搜索 / 展开 / 编辑——与书架、阅读器对齐合并为 M10.6，B4 ✅ 代码/单测/文档完成（2026-10-18，树列表 + 搜索 + 编辑页），真机待验 |
| M9.4 | GTD：agenda 视图增强（M4 基础上）——并入 M10.6 B4 ✅ 代码/单测/文档完成（2026-10-18，Notes 的 Agenda 段取代 GTD 入口 + `NotesSync` 统一数据源与上传），真机待验 |
| M9.1b | 设置项扩展（8 项）+ tab 图标 + 阅读器连续滚动（PDF/EPUB 竖向零间隙）✅ 完成（2026-10-18），见 openspec/completed/2026-10-18-m9.2-settings-and-reader-scroll.md（编号用 M9.1b 以免与上表已有的 M9.2「数据源接入」冲突） |

### M10 Android Reader

| 子项 | 内容 |
|---|---|
| M10.1 | 书架（元数据来自服务端，封面/进度/按需下载）——本地书架 ✅ 完成（M10.6 B3，2026-10-18，真机待验）；服务端元数据/按需下载待做 |
| M10.2 | 阅读增强（目录/主题/字体/跳转）——字号/翻页模式已随 M9.2 落地；工具栏显隐/SeekBar/目录 ✅ 完成（M10.6 B2，真机待验） |
| M10.3 | 批注侧车 + `location` 约定统一（PDF `page:<n>`+范围；EPUB 待定） |
| M10.4 | 进度/批注 uid 化同步 |
| M10.5 | **PDF 阅读增强**（用户 2026-10-18 提出，未开工，需另行走方案确认与计划确认）：手写批注（笔迹侧车，不写回 PDF）、点击翻页、横向翻页 / 竖向连续滚动双模式（滚动时页间首尾相接，保留上页最后一行）、横屏适配（fitWidth / fitHeight 选择）、后台渲染线程 + 位图 LRU 缓存（依赖 M10.1）✅ 完成（2026-10-18，手写批注 + 点击翻页 + 横屏），见 openspec/completed/2026-10-18-m10.5-pdf-ink-and-paging.md |
| M10.7 | **笔记库与渲染阅读**（用户 2026-10-18 确认）：多文件笔记库（私有目录 + 可选 SAF 外部目录，framework `DocumentsContract` 零新增依赖）、org / markdown 渲染阅读页（WebView + 自研渲染器）、文件级源码编辑（`NoteEditActivity`）、设置页「笔记外部目录」（SAF 持久授权）✅ 代码/单测/文档完成（2026-10-18，单测 468 → 562 例），真机待验——见 openspec/active/2026-10-18-m10.7-notes-reader.md |

### M11 批注与引用闭环

| 子项 | 内容 | 备注 |
|---|---|---|
| M11.1 | emacs-reader 文本提取（C 模块扩展） | ✅ PoC 通过（2026-10-12）；见 notes/openspec/completed/2026-10-12-m11.1-emacs-reader-text-poc.md |
| M11.2a | vendor reader 源码，建 seshat-reader 包 | ✅ vendor 与验证完成（2026-10-12），配置切换已完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-seshat-reader-vendor.md |
| M11.2b | 阅读器鼠标选区取文（Phase 1） | ✅ 完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-m11.2b-reader-selection.md |
| M11.2c | seshat-reader 包彻底自研化改名（feature/符号/文件名/C 模块名统一 seshat-reader-*） | ✅ 完成（2026-10-12）；见 notes/openspec/completed/2026-10-12-m11.2c-seshat-reader-rename.md |
| M11.3 | Emacs 侧批注采集 + 侧车同步 | ✅ 完成（2026-10-16；L3 端到端待服务端可用时补验）；见 openspec/completed/2026-10-16-m11.3-reader-annotations.md |
| M11.4 | 双向引用（笔记 ↔ 批注/书籍） | ✅ 完成（2026-10-17）；见 openspec/completed/2026-10-16-m11.4-cross-references.md |
| M11.5 | 阅读器翻译/解释（go-translate + posframe） | ✅ 完成（2026-10-16）；见 openspec/completed/2026-10-16-m11.5-reader-translate.md |
| M11.6 | 批注离线优先 + 自动同步（本地队列、幂等去重、自动推进） | ✅ 完成（2026-10-16）；见 openspec/completed/2026-10-16-m11.6-annotation-offline.md |
| M11.7 | 阅读器信息面板（底部弹出，批注 / 译文 / 解释统一承载） | ✅ 完成（2026-10-17，含承载方式返工：底部弹出 + per-kind 高度）；见 openspec/completed/2026-10-16-m11.7-reader-sidebar.md |
| M11.8 | 底部面板交互优化（光标跟随 · popper 开关 · 便捷键位） | 部分完成（2026-10-17）：光标跟随、popper 分流、面板内键位（由 M11.9 的 `:keys` 承担）已完成；**T6 全局 `SPC o P` 入口待办**；见 openspec/completed/2026-10-17-m11.8-sidebar-ux.md |
| M11.9 | 面板 ETAF 渲染层（批注卡片化 + 译文排版，可选软依赖） | ✅ 完成（2026-10-17）；ETAF PoC 判可行（加载 0.09s / 首渲染 0.002s / 零 warning / 无 native 依赖）；见 openspec/completed/2026-10-17-m11.9-etaf-render.md |
| M11.10 | 阅读器面板渲染重构：译文/解释改 Markdown 文本 buffer + 批注分页 | ✅ 完成（2026-10-18）；见 openspec/completed/2026-10-18-reader-panel-markdown-and-paging.md |
| M11.11 | 译文/解释面板 Markdown 模板与初始高度（模板可配置 + 高度下限可配置） | ✅ 完成（2026-10-18）；见 openspec/completed/2026-10-18-reader-panel-markdown-template-and-min-height.md |
| M11.12 | 译文/解释面板模板拆分、去正文重复标题、原文默认显示 | ✅ 完成（2026-10-18）；见 openspec/completed/2026-10-18-reader-panel-template-split.md |
| M11.13 | 批注列表去分页，改单列连续流（全量渲染 + 按内容设置 ETAF viewport 高度） | ✅ 完成（2026-10-18）；见 openspec/completed/2026-10-18-annotation-list-continuous-flow.md |
| M11.14 | 译文/解释面板启用 visual-fill-column-mode（软依赖、可关） | ✅ 完成（2026-10-18）；见 openspec/completed/2026-10-18-reader-panel-visual-fill-column.md |

## 风险登记

| # | 风险 | 影响 | 缓解 |
|---|---|---|---|
| R1 | Emacs 同步器 WebDAV→REST 重写 | 已有完工功能回退 | 保留 WebDAV 兼容路径做灰度；先并行双跑再切换 |
| R2 | 改 emacs-reader（第三方包，pin 在 commit） | 维护成本、上游不接受 LLM 贡献 | M11.1 可独立/可放弃，先只做「进度」再评估批注 |
| R3 | `document_id`→`uid` 迁移 | 存量数据、Android prefs、Emacs 配置 | 按 `openspec/decisions.md`「C 数据契约域」纪律（复制 + 观察期） |
| R4 | Android UI 重构范围大 | 工期 | 与 M7 并行，先出静态骨架 |
| R5 | 未决范围（见下） | 返工 | 在对应里程碑开工前澄清 |

## 未决问题

1. 收录目录清单（哪些根、什么前缀）—— M7.2 需要 —— ✅ 已解决（M7.2 落地 `webdav.roots`：`tag`/`path`/`mode`，未配置时归一为单根 `notes`，2026-10-18）
2. GTD 深度（只读 / 可编辑 / repeater·DEADLINE·状态流转）—— M9.4 需要
3. Reader「基础功能」清单（排除 TTS/词典/统计？）—— M10 需要
4. EPUB 的 location 约定（CFI vs `chapter:x`）—— M10.3 需要 —— **仍未定**（M7 不解决；M7 只把「身份」从路径换成 uid，location 语义未变）
5. M11.8 T6（`SPC o P` 全局键位）未做，属 UX 待办（见 tech-debt）
6. PDF 手写批注的 `location` 协议（现有约定仅支持 `page:<n>;rect:x0,y0,x1,y1`，多点笔迹需扩展，例如 `page:<n>;ink:...`；需与 Emacs 端 rect 约定共存）—— M10.5 需要（已定稿：`page:<n>;ink:<color>,<widthPt>,<x0>,<y0>,...`，页面坐标，见 docs/api.md 4.5.1；2026-10-18）
7. 含 `#`/`%` 的文档名引用 —— ✅ 已缓解（M7 引入 uid 形态承载身份：服务端 `refs` 支持 uid 形态，解析不再受文件名字符限制；Emacs 侧 `seshat:` 链接文本仍为 doc-id 形态，故为「缓解」而非「解决」，见 tech-debt「含 `#`/`%` 的文档名不支持引用」）

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
