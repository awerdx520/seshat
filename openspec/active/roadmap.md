# Seshat 路线图（M7–M12）：资源 ID · 引用 · 增量同步

## 当前状态

- 阶段：Phase 4（Review & Document）· M12 及其后续（尺寸自适应重贴合、平滑适配 + `W`/`H` 持久模式）均已归档，`openspec/active/` 仅剩本路线图；下一个里程碑待定
- 已确认：整体方案 ✅（用户 2026-10-12 确认）、路线图 ✅（用户 2026-10-12 确认）；M7 方案 ✅ 与计划 ✅（用户 2026-10-18 确认）
- 加密：维持现有 TLS（反向代理终止）；**不做应用层加密**（用户已取消该需求）
- 下一步：M8（Emacs 端接入）需另行方案确认与计划确认
- 2026-10-19 进展：**M10.7 真机验收通过并归档**（七项全过；同步修 2 处缺陷：渲染页 toolbar 标题不随内容更新、笔记列表不读 `#+FILETAGS:`；新增 5 条 tech-debt，单测 562 → 566）；M9.1 / M9.2（设置项·连续滚动）/ M10.5（手写·点击翻页·横屏）/ M10.6-B1（服务端可选）已完成并归档；M10.6-B2（阅读器交互：浮层显隐·SeekBar·目录）、M10.6-B3（书架：封面网格·进度徽标·过滤排序·点击打开）、M10.6-B4（Notes：树列表·搜索·编辑页·GTD 并入 + `NotesSync` 抽取与数据源统一）代码/单测/文档完成（**真机验证通过**，2026-10-18/19，见 openspec/completed/2026-10-18-m10.6-reader-books-notes-alignment.md「B1~B4 全部完成（真机全通过）」）；M9.2 B 批（文件同步：接入 `ResourceIndex`/`SyncEngine`、服务端书架数据源、按需下载、本地导入上传（≤32 MiB）、元数据回填、`move` 跟随）代码/单测/文档完成（2026-10-19，真机验证通过，单测 566 → 641）；M7 服务端已完成（待提交）
- 2026-10-20 进展：**M10.8（阅读器 UX 重排与手写增强，7 项需求）与 M10.9（目录树形左侧抽屉）均已实现并归档**（代码已提交 `e50a23a` / `8c14494` / `0361faf` / `bb759f1` / `9e7ffd8` / `cd55316` / `c4a76d3`；单测 649 → **721** → **754**，含 1 例 skipped），**✅ 真机验证通过（2026-10-20，设备 24091RPADC / Android 16，EPUB 与 PDF 两个阅读器）**；`c4a76d3` 追加两项：进入阅读默认沉浸、手写参数面板移到屏幕右侧竖排浮条；文档已同步 `docs/android.md` §6 / `CHANGELOG.md` / `openspec/decisions.md` / `openspec/tech-debt.md`（新增 4 条未通过项）；破例引入 `com.tom-roush:pdfbox-android:2.0.27.0`（用户 2026-10-20 授权的唯一例外，见 decisions.md）
- 下一步：**M12 已完成并归档（openspec/completed/2026-10-22-m12-reader-ux-layout-and-highlight.md，残余视觉项待用户目视）；下一个里程碑待定；M10.3/M10.4 已归档，L3 真机待验；emacs-reader 尺寸自适应计划已归档（`openspec/completed/2026-10-22-emacs-reader-resize-refit.md`，2026-10-23；机制已由后续 `2026-10-23-emacs-reader-smooth-fit.md` 演进）**（M10.6 B2/B3/B4、M9.2 B 批、M10.8、M10.9 均已验收通过并归档）
- 2026-10-23 进展：阅读器**尺寸变化即时适配 + `W` / `H` 适配模式持久化**实施完成并归档（`openspec/completed/2026-10-23-emacs-reader-smooth-fit.md`）：L1 `make all` EXIT=0、警告集 33 条零新增（逐条 diff）；L2 全仓 ERT **379** 例全绿 / 0 unexpected / 0 skipped（resize 测试 30 → **67** 例）；**真机验收通过**（开关目录第一帧即居中、`W` / `H` 后仍居中、打开文档无「先小后大」；隔离实例逐帧测量 Δ≤0.5px）；文档已同步（CHANGELOG / decisions ×5 / tech-debt / VENDORED 第 ⑧+⑨ 项 / `docs/emacs-reader.md` §3+§12）。
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
| M12 | Emacs 阅读器：三分栏版式 · 目录导航 · 批注高亮 · 跨页衔接 · 引用闭环 | M11 | 中 | 中（需改 C 渲染器） |

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

**计划 A（地基）已完成并归档（2026-10-24）**，见 `openspec/completed/2026-10-24-m8a-emacs-sync-foundation.md`：新增 `seshat-transport.el`（统一 `(:status :headers :body)` 契约，后端 `rest`/`webdav` 可换，transport 层永不抛错）、扩展 `seshat-rest.el`（9 个端点封装 + 统一状态码解释，`seshat-rest--request` 降为薄包装以保护既有 4 处调用方）、新增 `seshat-state.el`（单 `.eld` 原子写，承载全局游标 / per-uid base blob / uid↔路径双索引 / dirty / 墓碑）。新增 3 个测试文件、118 例，全仓 ERT 399 → **517**（0 unexpected / 0 skipped）。**接入进度**：计划 B 已完成增量循环、条件写、move 检测与冲突合并；剩余 M8.4 多根分流、M8.5 `seshat:` link、M8.6 透明性验证归计划 C。

**计划 B（增量引擎）已完成并归档（2026-10-24）**，见 `openspec/completed/2026-10-24-m8b-incremental-engine.md`：同步切到 REST 增量（`changes` 游标、代价与变更数成正比），push 改条件写（`If-Match`/`If-None-Match`），新增本地 `size`/`mtime` 快照比对发现编辑与改名、`diff3` 三方合并（并修复既有参数顺序 bug）、根映射初始化（`seshat-sync-roots`）与 `seshat-sync-reset-roots` 命令。新增 120 例用例，全仓 ERT 517 → **637**（0 unexpected / 0 skipped）。**M8 剩余**：M8.4 多根分流（`/api/roots` 已消费，但 `ondemand` 的按需下载入口与 UI 未做）、M8.5 `seshat:` org-link follow、M8.6 透明性验证（denote/dired/org-agenda 零变化）——归计划 C。

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
| M9.2 | 数据源接入（uid + 增量 + 本地缓存 + 按需下载电子书）——A 批（Android 接 M7：uid 化 + 只读协议 + 索引 + 增量 + 阅读器 uid 接入）✅ 完成（2026-10-18），见 openspec/completed/2026-10-18-m9.2-android-m7-client.md；B 批（文件同步，支撑书架：远端清单、按需下载、导入上传 ≤32 MiB、元数据回填、`move` 跟随）完成并归档（2026-10-19，**真机验证通过**），见 openspec/completed/2026-10-19-m9.2b-file-sync.md |
| M9.3 | Notes：orgzly 风格列表 / 搜索 / 展开 / 编辑——与书架、阅读器对齐合并为 M10.6，B4 ✅ 代码/单测/文档完成（2026-10-18，树列表 + 搜索 + 编辑页），真机验证通过（2026-10-18/19） |
| M9.4 | GTD：agenda 视图增强（M4 基础上）——并入 M10.6 B4 ✅ 代码/单测/文档完成（2026-10-18，Notes 的 Agenda 段取代 GTD 入口 + `NotesSync` 统一数据源与上传），真机验证通过（2026-10-18/19） |
| M9.1b | 设置项扩展（8 项）+ tab 图标 + 阅读器连续滚动（PDF/EPUB 竖向零间隙）✅ 完成（2026-10-18），见 openspec/completed/2026-10-18-m9.2-settings-and-reader-scroll.md（编号用 M9.1b 以免与上表已有的 M9.2「数据源接入」冲突） |

### M10 Android Reader

| 子项 | 内容 |
|---|---|
| M10.1 | 书架（元数据来自服务端，封面/进度/按需下载）——本地书架 ✅ 完成（M10.6 B3，2026-10-18，真机验证通过 2026-10-19）；服务端元数据/按需下载 ✅ 随 M9.2 B 批完成（2026-10-19，真机验证通过） |
| M10.2 | 阅读增强（目录/主题/字体/跳转）——字号/翻页模式已随 M9.2 落地；工具栏显隐/SeekBar/EPUB 目录 ✅ 完成（M10.6 B2，真机验证通过 2026-10-18/19）；**PDF 真目录**与 tap 三分区 ✅ 完成（M10.8，✅ 真机验证通过 2026-10-20）；目录形态已由 M10.9 升级为树形左侧抽屉 |
| M10.3 | 批注侧车 + `location` 约定统一（PDF `page:<n>`+范围；EPUB 待定）— ✅ **已完成并归档（2026-10-22）**，见 `openspec/completed/2026-10-22-m10.3-m10.4-annotation-loop.md`；L3 真机验收待用户确认。v8 契约已定稿（`annotations` 增 `kind` / `selected_text`，`text` 校验按 kind 分支，`(uid,kind,location,text)` 幂等命中 200）；EPUB location 定稿为 `chapter:<spineIndex>@<startOffset>-<endOffset>`（见 `docs/api.md` §4.6 与 `openspec/decisions.md` 2026-10-22 三条） |
| M10.4 | 进度/批注 uid 化同步 — ✅ **已完成并归档（2026-10-22）**，见 `openspec/completed/2026-10-22-m10.3-m10.4-annotation-loop.md`；**进度 409 已于收尾轮实现**「重拉比较 + 带新时间戳重发」（`pushProgressDetailed`，见 `openspec/tech-debt.md` 2026-10-22「已解决」条）；遗留仅 Activity 三态 UI 无 JVM 单测（只能真机/人工验收）。批注 merge 按 `(kind, location, text)`、409 以服务端为准 + 冲突提示、`DELETE` 404 视为成功、离线待删队列 `pending_deletes_<uid>` |
| M10.5 | **PDF 阅读增强**（用户 2026-10-18 提出，未开工，需另行走方案确认与计划确认）：手写批注（笔迹侧车，不写回 PDF）、点击翻页、横向翻页 / 竖向连续滚动双模式（滚动时页间首尾相接，保留上页最后一行）、横屏适配（fitWidth / fitHeight 选择）、后台渲染线程 + 位图 LRU 缓存（依赖 M10.1）✅ 完成（2026-10-18，手写批注 + 点击翻页 + 横屏），见 openspec/completed/2026-10-18-m10.5-pdf-ink-and-paging.md |
| M10.7 | **笔记库与渲染阅读**（用户 2026-10-18 确认）：多文件笔记库（私有目录 + 可选 SAF 外部目录，framework `DocumentsContract` 零新增依赖）、org / markdown 渲染阅读页（WebView + 自研渲染器）、文件级源码编辑（`NoteEditActivity`）、设置页「笔记外部目录」（SAF 持久授权）✅ **完成并归档**（2026-10-18 开发，单测 468 → 562 例；2026-10-19 真机验收通过并修 2 处缺陷，单测 562 → 566 例）——见 openspec/completed/2026-10-18-m10.7-notes-reader.md |
| M10.8 | **阅读器 UX 重排与手写增强**（用户 2026-10-20 确认 7 项需求）：① 浮层改纯 overlay + padding 随可见性联动（修「隐藏浮层后底部留白」）；② tap 三分区（左/中/右 = 上一屏 / 切浮层 / 下一屏，纯函数 `TapZone`）；③ 工具栏重排（顶栏导航与目录、底栏只留进度条 + 可点页码）；④ EPUB 与 PDF **真目录**（PDF 经破例引入的 PdfBox-Android 读书签树，含 50 MiB / 深度 64 / 节点 5000 三重上限）；⑤ 书架三按钮并为单一「导入书籍」（按扩展名自动识别，示例书改为空库静默播种）；⑥ 封面三级回退 + 书名首字占位；⑦ 手写笔型（钢笔/马克笔/荧光笔）+ 手写面板 + 双击进退 + 长按菜单。**已完成：代码已提交 · ✅ 真机验证通过（2026-10-20）**：commit `e50a23a`、`8c14494`、`0361faf`、`bb759f1`、`9e7ffd8`、`c4a76d3`，单测 649 → **721**（1 例 skipped）；文档已同步（`docs/android.md` §6、`CHANGELOG.md`、`openspec/decisions.md`、`openspec/tech-debt.md`），已归档，见 openspec/completed/2026-10-20-m10.8-reader-ux-polish.md |
| M10.9 | **目录改为树形左侧抽屉**（M10.8 的 `AlertDialog` 扁平目录体验不足）：EPUB 侧新增 `EpubParser.parseNavTree` / `parseNcxTree` 保留 nav / NCX 层级（`href` 用 nav/ncx **文档自身目录**归一化，暴露 `EpubBook.tocTree`，既扁平 `parseNav` / `parseNcx` 不动），PDF 书签树复用同一行模型；左侧滑出抽屉（遮罩 + `translationX` 动画，面板宽 `min(320dp, 屏宽 × 0.78)`，**不用 `DrawerLayout`** 以免边缘滑动手势与横向翻页抢事件，零新增 XML / 零 `R.id.`）；`TocRows`（树 → DFS 前序行）与 `TocFlatten.visibleRows`（折叠）为纯函数，行 `id` 用 DFS 兄弟序号路径（容器节点与同 href 不同锚点都不串扰）；打开即展开当前章 / 页的祖先链并滚动定位，点箭头折叠、点标题跳转，返回键优先关闭抽屉、收起工具栏一并收起，抽屉为覆盖层不触碰阅读区 padding；PDF 无书签仍回退「第 N 页」页码目录。**已完成：代码已提交 · ✅ 真机验证通过（2026-10-20，EPUB 与 PDF 两个阅读器）**——commit `cd55316`，单测 721 → **754** 例（+33），已归档，见 openspec/completed/2026-10-20-m10.9-toc-drawer.md。后续追加：**进入阅读默认沉浸 + 手写工具栏移至右侧**（`c4a76d3`） |

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

### M12 Emacs 阅读器（已完成）

**已完成 2026-10-22**，见 `openspec/completed/2026-10-22-m12-reader-ux-layout-and-highlight.md`。

| 子项 | 内容 | 状态 |
|---|---|---|
| T1 | 修复目录中文乱码（`outline2plist` 的 outline 标题 UTF-8 安全构造，目录与 imenu 同口径） | ✅ 2026-10-22 |
| T2 | sidebar 支持 left/right side window（`seshat-reader-sidebar--display-params` 按方向返回 `display-buffer-in-side-window`、宽度 defcustom、方向感知尺寸读写） | ✅ 2026-10-22 |
| T3 | per-kind 多面板共存（kind→窗口映射、`seshat-reader-sidebar--slot-for-kind` 分槽、`toggle` 可选 kind、`C-c C-o` 键位） | ✅ 2026-10-22 |
| T4 | 目录面板接入 sidebar + 每次 show 都重建（修「buffer 非空不重建」） | ✅ 2026-10-22 |
| T5 | 目录面板美化（行模型纯函数 `seshat-reader-outline--rows`：层级缩进 / 折叠符号 / 页码右对齐 / 三级 face / 当前章竖线） | ✅ 2026-10-22 |
| T6 | avy 式跳转（`f` 键、实读 avy 源码后选择零依赖自实现、overlay 标签 + `read-key` 逐键匹配） | ✅ 2026-10-22 |
| T7 | 跨页衔接 PoC（`:slice` + 行高 + `:ascent` + vscroll 定位 + `--center-page` 兼容性三条判据） | ✅ 2026-10-22 |
| T8 | 跨页保留上页末行（strip 行 + 翻页 vscroll 定位、书签 vscroll 语义、`--at-page-top-p` 谓词、关闭开关等价性） | ✅ 2026-10-22（T8a/T8b） |
| T9 | C 层 rect 高亮绘制（`DocState` 高亮表 + 渲染线程快照 + `draw_page_thread` 绘制 + 三个模块函数 + 缓存失效） | ✅ 2026-10-22 |
| T10 | elisp 侧高亮同步（`--rects-from-location` + `--apply-highlights` + 开关 + `C-c C-h` 刷新命令 + 两处零新增请求挂接点） | ✅ 2026-10-22 |
| T11 | `seshat:` 链接 `:complete`（候选来自 annotation-roots 的文件清单，可选 `#page:<n>`） | ✅ 2026-10-22 |
| T12 | `seshat:` 链接 `:export`（输出「文件名 第 N 页」可读文本，不生成假 URL） | ✅ 2026-10-22 |
| T13 | 摘录按位置插入（`seshat-reader-reference-insert-position`：`end-of-file` / `headline` / `point`） | ✅ 2026-10-22 |
| T14 | `--parse-link` 尾部 `#` 的空 location 归一为 nil | ✅ 2026-10-22 |
| T15 | 文档沉淀（CHANGELOG / architecture / configuration / api / decisions / tech-debt / VENDORED / roadmap） | ✅ 2026-10-22 |
| T16 | 全量验证与归档（`make clean all` + 全部 ERT 无 skipped + L3 验收清单，计划移入 `openspec/completed/`） | ✅ 2026-10-22 |

配套决策见 `openspec/decisions.md` 的两条 2026-10-22 条目（side window 三分栏、C 层高亮绘制）；已知限制见 `openspec/tech-debt.md` 的 M12 条目（旋转页高亮可能错位、`ink:` 仍不显示、高亮颜色不可配置、多窗口 strip 缓存局限等）。

**状态：✅ 已完成并归档（2026-10-22）**；L1/L2 全绿（271 用例 0 unexpected / 0 skipped），L3 功能级经隔离实例验证 46 条断言全过；残余视觉项（高亮绘制观感、三栏布局、配色）待用户目视，不阻塞归档

### M12 后续：阅读器窗口尺寸自适应

计划与执行记录：`openspec/completed/2026-10-22-emacs-reader-resize-refit.md`（**已归档，2026-10-23**）。

- 内容：窗口尺寸变化（开关目录/批注面板、拖分割线、新窗口）后重新贴合页面——`scale-source`（fit/manual）、`--contain-scale`（min 按高/按宽）、`--clamp-window-vscroll`、idle 去抖 + 1% 偏差闸 + `--refitting` 防重入、`--recenter-window` 同步居中；并修两处边界缺陷（换 buffer 后 hscroll 归零、首次打开抛 `wrong-type-argument`）。
- 状态：**✅ 已归档（2026-10-23）**——代码 + 单测 + 文档完成（归档时 `seshat-reader-resize-test.el` 30 例、全仓 ERT 342 例 0 unexpected；T5 文档六件套与 tech-debt 四条均已落地）；真机验收由后续 `2026-10-23-emacs-reader-smooth-fit.md` 覆盖，L3-6（短页 vscroll 非负）与 L3-8（daemon）两项记为待观察。**机制演进**：1% 偏差闸 → `render-scale` 清晰度闸；`line-prefix` + hscroll 居中 → `before-string` + `:align-to`（redisplay 求值）。

### M12 后续：阅读器尺寸变化即时适配 + `W` / `H` 适配模式持久化

计划与执行记录：`openspec/completed/2026-10-23-emacs-reader-smooth-fit.md`。

- 内容：① `W` / `H` 升级为**持久适配模式**（window parameter `fit-mode` 取 `contain` / `width` / `height`，`--fit-scale` 按模式求目标 scale）——修「按 `W` 后开关目录变回按高度」（适配维度在写入时被丢弃）；② 尺寸变化的几何适配改为**同步**——hook 内直接改写页面 image spec 的 `:width` / `:height`（`--apply-display-scale`，纯 elisp、不重渲染），第一帧即最终几何；C 侧重渲染降级为 idle 的「一次清晰化」（`--refit-window` 按 `render-scale` 是否等于 `scale` 决定，替换旧的 1% 偏差闸），消除「先跳动一下、再重新绘制」的两帧；③ **居中改由 redisplay 求值**（页面 overlay 的 `before-string` = `(space :align-to (+ center (-0.5 . IMAGE)))`，配合 `--centered-p` / `--ensure-centered` 与 buffer-local `pre-redisplay-functions`），彻底消除窗口尺寸变化时的中间帧（旧实现靠 `line-prefix` + `hscroll` 两段补偿，实测首帧偏 −524px）；超宽页仍走 `line-prefix` + 横向滚动；④ 首次打开改走 `--first-fit`（显示层缩放一步到位，不再「先画小图再重渲染大图」）；⑤ 拖拽抑制 `--drag-threshold`（0.12 秒）：连续尺寸变化只居中不缩放，避免逐帧重缩放位图；⑥ 新增 `--native-page-size`（按页号缓存的未缩放像素尺寸）与 `render-scale`（清晰度闸）；⑦ 契约变更：resize 测试中原「1% 偏差闸」两例改为「`render-scale` 相等则不重渲染」，另有多例按新的居中机制调整断言（未删用例、未弱化断言）。
- 状态：**已完成（2026-10-23），真机验收通过**：L1 `make all` EXIT=0、警告集 33 条零新增（逐条 diff）；L2 全量 11 个测试文件 **379 例全绿 / 0 unexpected / 0 skipped**（resize 测试 30 → **67** 例，新增 37 例），变异自检 3 处；隔离实例逐帧测量开关目录 / `W` / `H` / 新窗口的首帧误差 ≤0.5px；真机验收六项全过（`o` 开关目录第一帧居中、`W` / `H` 居中、打开文档无「先小后大」）。文档已同步 `CHANGELOG.md` / `openspec/decisions.md`（五条）/ `openspec/tech-debt.md` / `emacs/seshat-reader/VENDORED.md`（第 ⑧ + ⑨ 项）/ `docs/emacs-reader.md`（§3、§12）。保留残余项（超宽页左对齐、join strip 与居中未验证、image cache 峰值未观测）已记 tech-debt；**零新增 defcustom**（`docs/configuration.md` 不改）。

### M12 后续：阅读器适配默认值（`seshat-reader-default-fit` 重定义）

计划与执行记录：`openspec/completed/2026-10-23-reader-default-fit-mode.md`（**已归档，2026-10-23**）。

- 内容：把 `seshat-reader-default-fit` 从「自动 fit 路径零调用点的 no-op」重定义为**新窗口/新文档的初始适配模式**（`contain` / `width` / `height`，默认 `contain`），旧函数符号值兼容映射；新增 `--normalize-default-fit` / `--initial-fit-mode`，接入 `--first-fit` 与 `--window-create-function`；`W` / `H` 仍只作用于当前窗口、不跨会话。附带一次真机批量观测，清 L3-6 / L3-8 / `image-flush` 移除后回收 / image cache 峰值 / strip 与 `before-string` 居中交互等技术债。
- 状态：**✅ 已完成并归档（2026-10-23，`openspec/completed/2026-10-23-reader-default-fit-mode.md`）**——代码 + 单测（`seshat-reader-resize-test.el` 67 → **80** 例，全仓 ERT 384 → **397**，0 unexpected / 0 skipped；L1 警告集 33 → 33）；文档 8 项全部落地；真机观测 4/5 项完成：T4-1（L3-6 短页 vscroll 非负）✅ 通过、T4-2（idle timer）⚠️ 非 daemon 通过而 daemon 场景未验证、T4-3（`image-flush` 移除后回收）✅ 通过（20 次开合 +1.79 MB）、T4-4（拖拽期间 cache 零增长）✅ 通过（`--drag-threshold` 生效）、T4-5（strip 与 `before-string` 交互）按用户决定不执行。观测中发现的**新缺陷**（`revert-buffer` 后 buffer 保持 modified，与 `super-save` 冲突、解除只读后有写坏 PDF 风险）已记 `openspec/tech-debt.md`，并**已于 2026-10-23 修复**——`seshat-reader--render-buffer` 与 `--update-join-strip` 各补 `(set-buffer-modified-p nil)`，新增 ERT 2 例（`seshat-reader-page-join-test.el` 24 → 26，全仓 **397 → 399**，0 unexpected / 0 skipped）。

### 阅读模式：通用阅读 vs Seshat 阅读（已完成）

计划与执行记录：`openspec/completed/2026-10-24-reading-mode-library-decoupling.md`（**已归档，2026-10-24**）。

- 内容：新增 `seshat-reading-mode`（派生自 `seshat-reader-mode`，接管 `auto-mode-alist`），在 mode-line 显示库身份四态，身份解析零网络；新增 `seshat-library-add`（复制上传、保留原件）与 `seshat-reading-refresh`（唯一显式触网入口）；库外文档的降级警告静音；reader 中 3 处 `eq major-mode` 改为 `derived-mode-p`。
- 状态：**已完成并归档（2026-10-24）**——全仓 ERT 637 → **669**（19 个文件，0 unexpected / 0 skipped）；L3 真机 5 项待人工（`find-file` 进 reading-mode、四态显示、入库后自动 `[库]`、库内批注可见、纯 reader 仍可批注）。
- 关系：本计划**不替代** M8.4 多根分流与书籍列表 UI；「库外批注 + 入库迁移」记 tech-debt。

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
4. EPUB 的 location 约定（CFI vs `chapter:x`）—— M10.3 需要 —— ✅ 已定稿（2026-10-22）：`chapter:<spineIndex>@<startOffset>-<endOffset>`（spine 0-based、章内字符偏移半开区间、UTF-16 code unit；退化形态 `chapter-<n>`），见 `docs/api.md` §4.6 与 `openspec/decisions.md` 2026-10-22
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
