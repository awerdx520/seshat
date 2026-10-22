# Changelog

本项目所有值得注意的变更记录于此文件。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### 新增

- 服务端文件身份（M7）：新增 `resources` 表与 26 位 Crockford Base32 `uid`（`crypto/rand` 16 字节，零新增依赖），路径降级为可变属性——改名/移动后 `uid` 不变，三端身份收敛到同一个 uid。详见 `docs/adr/0003-uid-identity-model.md`。
- 服务端变更流（M7）：新增 `changes` 表与全局单调 `seq`，`GET /api/changes?since=<seq>` 增量拉取；删除写墓碑并保留 `delete` 事件，客户端可感知删除。详见 `docs/adr/0004-incremental-change-log.md`。
- 服务端引用图（M7）：新增 `refs` 表记录 `seshat:` 引用（`tag:path` 与 uid 双形态），`GET /api/refs?uid=&direction=in|out` 双向查询引用关系。
- 服务端资源端点（M7）：`GET /api/resources`（按 `?root=` / `?prefix=` 过滤，`limit` / `has_more` 分页）、`GET /api/resources/{uid}`、`GET /api/resolve`（`?root=&path=` → uid，客户端获取 uid 的唯一入口）、`GET /api/roots`（下发多根映射）、`POST /api/resources/rescan`（按文件系统重建登记）。
- 服务端文件端点（M7）：`GET|PUT|DELETE /api/files/{path...}`（ETag / `If-Match` 乐观锁 / 单区间 Range）与 `POST /api/resources/{uid}/move`（改名/移动保持 uid）。
- 多根映射（M7.2）：配置 `webdav.roots`（`tag` / `path` / `mode`），`mirror` 根（笔记根，挂 WebDAV 全量镜像 + FTS）与 `ondemand` 根（书库根，按需读取）并存；未配置时归一为单根 `notes`（向后兼容），`GET /api/roots` 下发。
- 启动全量登记（M7.4）：服务启动时调用 `registry.Bootstrap` 幂等登记全部根下的文件，用 size / mtime / blob hash 快跳未变更文件。
- Emacs 客户端 uid 适配（M7，B5）：`seshat-rest.el` 新增 `seshat-rest-resolve-uid`（`root` + `path` → uid）；批注模块改为**双值**——`doc-id` 只用于显示与 `seshat:` 链接文本、`uid` 只用于调 API（列表 buffer 同时持 `seshat-reader-annotation-list-document-id` 与 `seshat-reader-annotation-list-uid`）。
- Android PDF 手写批注、点击翻页与横屏适配（M10.5）：① **手写批注**——在页面位上自由绘制（`InkOverlayView`），支持撤销上一笔与清除本页；笔迹以归一化坐标（相对页面显示矩形 0..1）存于本地 `PdfInkStore`（`pdf_ink_<docId>`），跨横竖屏与不同渲染分辨率天然对齐（坐标换算由纯函数 `InkGeometry` 承担，11+ 例单测覆盖 FIT_CENTER 留白算例）；「阅读 / 手写」双模式切换，手写时拦截手势并显示「上一页 / 下一页」。② **点击翻页**——横向模式点击左右各 30% 翻页、中间 40% 切换工具栏；`onInterceptTouchEvent` 恒返回 false，不吞滑动与吸附。③ **横屏适配**——横向模式按可用高度 × 首页宽高比计算渲染宽度（减少留白），底部工具栏改为贴底半透明浮层并按 `WindowInsetsCompat` 避让系统栏。新增 JVM 单测 24 例（`InkGeometryTest` 12 / `PdfInkStoreTest` 12），单测总数 225 → 249。**手写批注仅本地保存，尚未接入服务端同步**（`location` 的 ink 协议已写入 `docs/api.md` 4.5.1）；**UI 与笔迹对齐需真机验收**（本机无 AVD / 设备）。
- Android 设置项扩展与阅读器连续滚动（M9.2）：① 设置页从 2 项扩展到 **8 项**——新增 WebDAV 远程目录、主题（跟随系统/浅色/深色，切换即时生效）、EPUB 正文字号（80–200%）、翻页模式、连通性测试（`GET /api/annotations?document_id=__connectivity_probe__`）与「关于」（版本号 + 配置状态）；② 底部 tab 补上自绘矢量图标；③ **PDF 与 EPUB 均支持竖向连续滚动**（页/章间零间隙），PDF 换成 `RecyclerView` + 单线程后台渲染 + `LruCache(maxMemory/8)` 位图缓存 + 横向 `PagerSnapHelper` 吸附，EPUB 竖向用 `RecyclerView` + 每章一个高度自适应 `WebView`（禁复用 + 测量后重锚）；④ 新增非机密偏好层 `settings/AppPreferences`（`seshat_app_prefs.xml`，与加密层分离，加密不可用时主题/阅读偏好仍可用）与 `SeshatApp`（启动时应用主题）；⑤ 新增 `ScrollProgressMath` 纯函数统一两种模式的进度换算。新增 JVM 单测 36 例（`AppPreferencesTest` 18 / `ConnectivityTesterTest` 8 / `ScrollProgressMathTest` 10），单测总数 179 → 215。**零新增依赖。**
- Android 三区 UI 骨架（M9.1）：`MainActivity` 由 5 个按钮的入口页改造为单 Activity Shell——顶部 `MaterialToolbar`（标题随 tab 变化 + 溢出菜单「设置」）、中部 `FragmentContainerView`、底部 `BottomNavigationView` 双 tab（笔记 / 阅读）。新增 `ui/NotesFragment`（GTD 入口，列表待 M9.3）与 `ui/ReaderFragment`（迁入示例 EPUB / 选择 EPUB / 选择 PDF / 导入书籍 4 个入口，行为不变）。新增设置页 `settings/SettingsActivity`：服务端地址与访问令牌（令牌经 `EncryptedSharedPreferences` 加密、不回填明文、留空即保留原值；地址校验与规范化见 `settings/SettingsValidator`），填补「App 内无处配置同步服务器」的缺口。新增 JVM 单测 29 例（`MainTabTest` 6 / `SettingsValidatorTest` 16 / `SettingsStoreTest` 7），单测总数 136 → 165。构建配置：显式声明 `androidx.fragment:fragment:1.5.4`、删除重复的 `viewpager2` 声明、修正 `gradle.properties` 过时注释。**无新增第三方依赖**；`gtd/`、`reader/`、`sync/`、`importer/` 零改动。**UI 观感需真机验收（本机无 AVD / 设备 / 系统镜像）。**
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
- 译文/解释面板 **Markdown 模板**（M11.11，2026-10-18）：新增 `seshat-reader-translate-template`（默认 `"# %k\n\n%l\n\n%q\n\n---\n\n%t\n"`，`nil` 退回纯正文），正文按「标题 + 语言对（`*en → zh*`）+ 可选原文引用块（`> **原文**`）+ 分隔线 + 正文」渲染；占位符由 `--format-langs` / `--quote-block` 生成，模板非法时回退纯正文并警告。`--render-panel` / `--render-object` 新增可选 `langs` 参数（向后兼容）。
- 译文/解释面板**高度下限可配置**（M11.11，2026-10-18）：新增 `seshat-reader-sidebar-min-height`（默认 `0.25`，至少 1 行），自适应高度区间改为 `min-height`–`max-height`；`--content-height` 单行像素高改取首行与 `frame-char-height` 的较小值（避免标题行导致行数低估），测量上限 40 → 120 行。批注列表高度不受影响。
- 译文/解释面板**模板拆分与原文默认显示**（M11.12，2026-10-18）：`seshat-reader-translate-template` 默认值改为 `"%l\n\n%q\n\n---\n\n%t\n"`（去掉正文标题，header-line 继续显示「Seshat 译文/解释」）；新增 `seshat-reader-translate-explain-template`（默认 `"%q\n\n---\n\n%t\n"`，解释面板独立模板，`nil` 退回纯正文且不借用翻译模板）；`seshat-reader-translate-show-source` 默认值改为 `t`（默认显示原文引用块）。`--apply-template` / `--render-panel` / `--render-object` 以可选 `context` 参数选择模板。
- 批注列表**去掉分页，改为单列连续流**（M11.13，2026-10-18）：删除 `seshat-reader-annotation-page-size`、当前页/buffer-local 页号、`--page-count`/`--clamp-page`/`--page-items`、4 个翻页命令与 `]`/`[` 键位、纯文本页脚，以及 ETAF 的 `--page`/`--page-count`/`--page-of-index`/`--sync-page-with-selection`；全量条目一次性单列渲染，徽章恒为「N 条」，`n`/`p` 只移动选中。ETAF 卡片列表去掉固定 12 行高度与内部滚动，改按条目数**显式计算 viewport 高度**（已挂载时 `etaf-runtime-refit`），面板窗口整体滚动。
- 译文/解释面板启用 **visual-fill-column**（M11.14，2026-10-18）：新增 `seshat-reader-translate-visual-fill-column`（默认 `t`），面板正文按 `visual-fill-column-width`（nil → `fill-column`）缩窄/居中；`visual-fill-column` 为软依赖，未安装时静默跳过；批注列表不启用（ETAF 按窗口宽度布局）。关闭时显式 `-1` 清理窗口 margin。
- Android 接入 M7 只读协议（M9.2 A 批，2026-10-18）：`sync/RestClient` 新增 `GET /api/roots`、`GET /api/resources`、`GET /api/resolve`、`GET /api/changes` 四个只读端点（int64 字段一律 `Long`，`next_cursor` / `has_more` / `old_path` 走 `@SerialName`）；新增本地资源索引 `sync/ResourceIndex`（`SharedPreferences("seshat_resource_index")` 单文件 JSON，`ResourceEntry` + 单一 `cursor`，属派生状态——可 `clear()` 后 `bootstrap()` 重建）与增量同步引擎 `sync/SyncEngine`（`bootstrap()` / `pull()`，每页先应用事件再存游标、崩溃最多重复一页、分段批量落盘消除 O(N²) 写放大）；阅读器支持可选 `EXTRA_UID`，**有 uid 且服务端已配置**时同步进度/批注，无 uid（SAF 直接打开）时完全离线（零网络调用）。**A 批不接线 `SyncEngine`**（书架 B 批接入），故二者当前是「可测但无调用方」的能力储备。单测总数 260 → 336（新增 `ResourceIndexTest` / `SyncEngineTest` / `ReaderSyncTest` / `LegacyKeysTest` / `Rfc3339Test` 等）。**零新增依赖。**
- EPUB 章节目录（M10.6 B2）：新增底部 `SeekBar`（拖动中不跳、松手跳章）、点击标题栏章号输入章号跳转（非法输入提示「章号无效」）与「目录」对话框（当前章高亮、点击跳章并关闭，nav/NCX 已扁平化为无层级列表）。
- PDF 页导航（M10.6 B2）：底部 `SeekBar` 拖动松手跳页、点击页码输入页号跳转；页码/进度指示在布局型跳转后用 `doOnNextLayout` 补齐同步。
- EPUB/PDF 阅读区底部 padding 自适应浮层高度（M10.6 B2）：阅读区 `clipToPadding = false` + padding = 浮层运行时高度（首次布局后写入、高度变化时跟随），页尾/章尾内容不再被叠加的浮层遮挡。
- Android 本地书架（M10.6 B3）：`ReaderFragment` 改为「过滤/排序条 + 封面网格」，数据源仅本地 `filesDir/books/`。网格列数按屏宽 2/3/4 列（<400dp / ≥400dp / ≥600dp），每格封面 + 标题 + 作者 + **进度徽标**（0% 不显示）；过滤「全部 / 未读 / 在读 / 已读」与排序「最近阅读 / 书名 / 导入时间」均为纯函数 `BookShelfLogic`；点击 EPUB 进 `EpubReaderActivity`（内容哈希作键）、PDF 进 `PdfReaderActivity`（`file://` 作键）。**零新增依赖。**
- EPUB 元数据扩展（M10.6 B3）：`EpubParser` / `EpubBook` 新增作者（OPF `dc:creator`，缺失为 `null`）与封面（manifest 中 `properties="cover-image"` 的项，暴露 `coverHref`）。
- Android 封面缓存（M10.6 B3）：新增 `reader/CoverCache`——内存 `LruCache<String, Bitmap>`（按 `byteCount`，上限 `Runtime.maxMemory() / 8`）+ 磁盘 `filesDir/covers/<key>.jpg`，并把书籍元数据另存 `<key>.json` 以**避免重复解析 EPUB 与重算内容哈希**；缓存键为 `文件名 + length + lastModified` 的 SHA-256 前 16 位 hex（`reader/CoverKeys`），PDF 封面用首页 `PdfRenderer` 渲染并按 `inSampleSize` 降采样。
- 书籍扫描与进度枚举（M10.6 B3）：新增 `reader/BookLibrary`（扫描 `filesDir/books/` → 元数据 → 合并进度 → 过滤 → 排序，阻塞调用、须在后台线程）与 `reader/BookMetaReaders`（生产用 EPUB/PDF 元数据读取，PDF 只取页数不渲染）；`ReadingProgressStore` 新增 `all()`、`PdfProgressStore` 新增 `loadAll()` 供书架一次性枚举进度。新增 JVM 单测 4 个测试类共 42 例（`BookLibraryTest` 13 / `BookShelfLogicTest` 14 / `CoverKeysTest` 10 / `CoverCacheMetaTest` 5），单测总数 407 全绿（B2+B3 合计 336 → 407）。
- 示例书迁移到 `filesDir/books/`（M10.6 B3）：`assets/sample.epub` 首次复制到书籍目录后打开书架条目；旧路径 `filesDir/sample.epub` **保留不删**作为回滚点（进度键为内容哈希，迁移后同一本书的进度仍可见）。
- Android 笔记列表（M10.6 B4）：`ui/NotesFragment` 由占位视图改为真实 org 列表——`filesDir/notes/*.org` 经 `OrgParser` 解析 + `OrgTreeBuilder` 建树，按层级缩进展示、可折叠；每行为「状态徽标 + 标题 + `:tag:` 同行 + 正文首行摘要」（`item_note_entry`）；顶部搜索框对标题 + 正文做大小写不敏感的包含匹配（`OrgSearchMatcher`），命中保留祖先链并强制展开，输入 250ms 防抖；分段「笔记 / Agenda」——Agenda 段用 `GtdSorter.byEarliestDate` 扁平按最早日期排序，点击切换 TODO 状态。
- Android 笔记编辑页（M10.6 B4）：新增 `ui/NotesEditActivity`，标题 / 正文 / TODO 状态可编辑并写回 org（`OrgEditor` 行区间改写）；优先级、计划、截止、标签、属性**只读展示**。
- 抽取 `gtd/NotesSync` 并统一 GTD 数据源（M10.6 B4）：新增 `NotesSync.upload(context, file): NotesSyncResult`（`Ok` / `NotConfigured` / `Failed`）——阻塞、无 Toast、不建线程，经 `SecurePrefs` 取地址与令牌后 `PUT` 到 `remoteDir/seshat/<文件名>`；`GtdActivity` 与 Notes 的 Agenda 段共用该实现，删除重复的 `readSyncConfig()` / `joinPath()`。`GtdActivity` 改读 `filesDir/notes/sample.org`，与 Notes 列表**同一份文件**，旧 `filesDir/sample.org` 保留但不再读取。
- Android 笔记库与渲染阅读（M10.7，2026-10-18）：① **多文件笔记库列表**——`notes/NoteScanner` 扫私有目录 `filesDir/notes/` 与设置页可选的外部目录（SAF tree URI + 持久读权限），一个 `.org`/`.md` 文件一行（标题 + 格式/修改时间 + 标签：denote 文件名优先，回退 org `#+FILETAGS:`），标题回退链「denote 文件名 > 首个 heading > 文件名」；② **渲染阅读页**——新增 `ui/NoteViewActivity`，`notes/render/OrgHtmlRenderer` 与 `MarkdownHtmlRenderer` 自研把文本转 HTML（先转义再匹配行内标记、代码块只转义不解析、链接走 `http`/`https`/`mailto` 白名单），`HtmlDocument` 提供统一内联 CSS（`prefers-color-scheme` 亮/暗），WebView 关闭 JS 与 file/content access；③ **文件级源码编辑器**——新增 `ui/NoteEditActivity`，整份源码纯文本编辑、后台读写、保留原行尾风格，仅对可写本地文件显示入口；④ 设置页新增「笔记外部目录」（SAF 选择 + 持久授权 + 清除）。单测 468 → 562 例，**零新增依赖**（不引 `androidx.documentfile`、markdown 库）。**渲染效果需真机验收（本机无 AVD / 设备）。**
- 书架接入服务端清单与同步装配（M9.2 B 批，2026-10-19）：接线 A 批已交付但无调用方的 `ResourceIndex` / `SyncEngine`。① `sync/SyncCoordinator` 装配 `SyncEngine` + `MetadataBackfill`，首次 `bootstrap()` / 之后 `pull()`，结果三态 `SyncOutcome`（`NotConfigured` / `Ok(applied, backfilled, cursor)` / `Failed`），**服务端未配置时全链跳过、零网络**；② `sync/SyncHolder` 提供**进程级单实例**（`ResourceIndex` 的锁是实例锁，多实例保护不了同一个 prefs 键）+ 单线程 executor（同步、回填、书架扫描串行）；③ `sync/MetadataBackfill`：`/api/changes` **不含** `size`/`mtime` → 新条目 `dirty = true`，按 `GET /api/resources` 的 `since`（mtime 秒）分页回填并清脏，同秒边界 `since += 1` 推进、`maxPages = 50`，**尽力而为 + 幂等**；④ `reader/RemoteBookSource` 从索引投影远端书籍，`BookLibrary` 按文件名与本地扫描结果合并——**未下载的书以占位条目进架**（无封面/作者、`totalCount = 0`、`isDownloaded = false`，`BookItem` 新增 `uid` / `isDownloaded` / `remote`）；⑤ 阅读器改为**按 uid 打开**（进度/批注同步闭环，纯本地无 uid 仍走内容哈希路径）；⑥ `SyncResult` 扩展 `renames`（`RenameEvent(uid, oldPath, newPath)`），`SyncCoordinator` 在 mirror 根上 best-effort 跟随本地文件名（仅当目标不存在时移动）。**零新增依赖**（不引 WorkManager / SwipeRefreshLayout / 协程）。
- 书架按需下载与本地导入上传（M9.2 B 批，2026-10-19）：① `sync/RestClient` 新增文件通道——`GET` / `PUT` / `DELETE /api/files` 与 `POST /api/resources/{uid}/move`（`downloadFile` / `uploadFile` / `deleteFile` / `moveResource` + DTO）；下载先写 `<name>.part`、`close()` 后原子改名、异常路径删 `.part`；上传前按 `MAX_UPLOAD_BYTES`（32 MiB，与服务端一致）前置拦截并抛 `IllegalArgumentException`，不发请求；② 新增 `reader/BookDownloader`：点击「未下载」条目 → `GET /api/files` → 落 `books/` → 自动打开阅读器，失败 `Toast`，下载中重复点击忽略；③ 本地导入成功后若 ≤ 32 MiB 自动上传（`If-None-Match: *` 新建）并回填索引 + 刷新书架，**超限只提示不上传**（本地文件保留）。单测 566 → 641 例（新增 `MetadataBackfillTest` / `SyncCoordinatorTest` / `SyncCoordinatorRenameTest` / `BookDownloaderTest` / `RemoteBookSourceTest`，`ResourceIndexTest` / `RestClientTest` / `SyncEngineTest` / `BookLibraryTest` 追加）。
- Android 阅读器 tap 分区与浮层 padding 联动（M10.8，2026-10-20）：① **浮层改为纯 overlay**——`EpubReaderActivity` / `PdfReaderActivity` 各新增 `applyContentPadding()`，按「浮层是否 `VISIBLE` + 当前 height」计算阅读区上下 padding，浮层隐藏即归零；幂等闸用 `appliedTopPadding` / `appliedBottomPadding`（EPUB 另加 `appliedContent` 比对 RecyclerView 身份）做「值未变不重写」以保住滚动锚点，布局监听改为**常驻**（字体缩放 / 旋转 / insets 变化都会重算），EPUB 末尾主动 `reportVisibleChapter()` 防止章内偏移漂移；两块浮层均注册 `ViewCompat.setOnApplyWindowInsetsListener` 避让系统栏。② **tap 三分区**——新增纯函数 `reader/TapZone.kt`（`zone(fraction, leftEdge = 0.25f, rightEdge = 0.75f)`）：左 `[0,0.25)` 上一章 / 上翻一屏、中 `[0.25,0.75]` 切浮层、右 `(0.75,1]` 下一章 / 下翻一屏；边界点归中间区、越界归一化、`NaN` 兜底 `TOGGLE`；竖向翻屏量 = 容器高扣掉浮层 padding。`OnItemTouchListener.onInterceptTouchEvent` 仍恒 `false`（不吞滚动）。单测 649 → 721（含 1 例 skipped）。
- Android PDF 真目录（M10.8，2026-10-20）：新增 `reader/PdfOutlineReader.kt`（读 PDF 书签树）、`reader/PdfTocEntries.kt`（条目构造与当前项定位）、`reader/PdfTextExtractor.kt`（单页文本提取）；顶栏「目录」弹出 `AlertDialog.setSingleChoiceItems`，`PdfTocEntries.indexForPage` 按当前页做初始高亮，无 outline 或解析失败回退「第 N 页」页码目录，`pageIndex < 0` 的书签（纯 URI 链接）点击时只关对话框不跳页。**安全上限**（针对不可信 PDF 输入）：`MAX_OUTLINE_BYTES = 50 MiB`（文件大小闸门）、`MAX_DEPTH = 64`（递归深度防栈溢出）、`MAX_NODES = 5000`（节点预算防海量兄弟书签撑爆内存），并用 `BoundedInputStream` **不信任** `ContentResolver.openAssetFileDescriptor().length`（provider 可谎报），把 50 MiB 从「provider 说了算」变回「App 说了算」；加密 / 损坏 / 超大 / 越界一律返回空表或空串，不抛异常。EPUB 侧目录入口从底栏移到顶栏。
- Android 封面三级回退与书名首字占位（M10.8，2026-10-20）：`EpubParser.pickCoverHref(manifest, epub2CoverId)` 按「EPUB3 `properties="cover-image"` → EPUB2 `<meta name="cover" content="id">` → manifest 中第一个 `media-type` 以 `image/` 开头的 item」回退，存量 EPUB2 旧书终于有封面；第三级是启发式（首图若是出版社 logo 会显示错图，记 tech-debt）。无封面或解码失败时书架卡片叠加 `coverInitial`（`CoverKeys.initialOf(title)` 取书名首字，大写，空书名 `?`），解码成功才隐藏。
- Android 手写笔型、手写面板与双击/长按（M10.8，2026-10-20）：① `InkStyle { PEN, MARKER, HIGHLIGHTER }`（`@Serializable`），`InkStroke` 新增 `style` 字段默认 `PEN`——旧 JSON 零迁移；`PdfInkStore.defaultJson()` 加 `coerceInputValues = true`，未知笔型回退默认值而非整份丢弃。② 渲染线宽倍率 1× / 2.2× / 3.5×、不透明度 255 / 170 / 90（`Paint.setColor` 后必须再设 `setAlpha`，否则颜色自带 alpha 覆盖笔型不透明度）。③ 手写面板（PDF 顶部浮层内 `inkPanel`，仅手写模式显示）6 色 × 3 档粗细（归一化 0.0025 / 0.004 / 0.007）× 3 种笔型，选中态 alpha 1.0 / 0.35，分「颜色 / 粗细 / 笔型」三行避免 360dp 屏溢出。④ 双击阅读区进入 / 退出手写，长按弹菜单（复制本页文字 / 高亮标注 / 进入手写），手写模式下单击不翻页（落笔优先）；「复制本页文字」用 `PDFTextStripper` 提取当前页，写剪贴板前截断到 10 万字符（防 binder 事务超限）。
- Android 目录树形左侧抽屉（M10.9，2026-10-20）：目录从 `AlertDialog` 扁平列表改为**左侧滑出的树形抽屉**。① **解析层**——新增 `TocNode` 与 `EpubParser.parseNavTree(navXml, baseDir)` / `parseNcxTree(ncxXml, baseDir)`，保留 `<ol><li>` 与 `<navPoint>` 嵌套；`TocNode.href` 是**已归一化的 epub 根相对路径**（用 nav/ncx **文档自身所在目录**作 base，nav 在子目录时也正确）；只有子项、自身无链接的容器节点 `title = ""` / `href = null`；`EpubBook.tocTree` 与既有扁平 `chapters` 并存，`parseNav` / `parseNcx` **一行未改**（仍服务章节标题匹配与分页），nav 解析为空时仍回退 NCX。② **行模型（纯函数）**——`TocRows`（`forEpub` / `forEpubFlat` / `forPdf`，树 → DFS 前序行并保留 depth）与 `TocFlatten.visibleRows`（按展开集合算可见行，单遍「可见深度上限」扫描，不重建树）；`TocRow.id` 用 **DFS 兄弟序号路径**（如 `"0/2/1"`），容器节点（`href` 为 null）与「同文件不同锚点」都不会撞车，祖先 id 即其各级前缀。③ **抽屉组件**——新增 `TocDrawer`（遮罩 + 面板 + `translationX` 动画，面板宽 `min(320dp, 屏宽 × 0.78)`）与 `TocAdapter`（行视图代码构建，缩进 `depth × 16dp`，箭头 `▸/▾`），全部视图代码构建、**零新增 XML / 零 `R.id.` 引用**，**不用 `DrawerLayout`**（其边缘横向手势会与横向翻页抢事件）；打开时自动展开当前章/页的祖先链并滚动到该项，点箭头折叠、点标题跳转，`targetIndex = -1` 的容器行点击只切折叠（不跳第一页），返回键优先关闭抽屉，收起工具栏时一并收起；抽屉是**覆盖层**，开合**不触碰**阅读区 padding。④ **PDF 回退**——无书签时 `PdfOutlineReader.pageDirectory(pageCount)` 的「第 N 页」列表转成同构树节点，复用同一行模型。新增 JVM 单测 33 例（`EpubParserTest` 14 / `TocRowsTest` 11 / `TocFlattenTest` 8），单测总数 721 → **754**。**零新增依赖；UI 观感与手势冲突需真机验收（设备离线，尚未验证）。**

- Emacs 阅读器**三分栏版式**（M12）：`seshat-reader-sidebar-position` 新增 `left` / `right` 两个取值（`display-buffer-in-side-window` + 独立 slot），侧栏与阅读区互不挤压；目录面板占左侧、批注/译文面板占右侧，三栏可同时存在（per-kind 独立窗口）；`C-c C-o` 收起/展开左侧目录。
- 阅读器**目录面板重做**（M12）：接入统一承载层（不再 `pop-to-buffer` 抢窗口）、切换文档后自动重建内容（修「换书后目录不更新」）、层级缩进 + `▾`/`▸` 折叠符号 + 页码右对齐 + 三级 face + 当前章节高亮（`line-prefix` 竖线）、`f` 触发 avy 风格单键跳转（零新增依赖，字符表复用 `avy-keys`）。
- 阅读器**批注页面高亮**（M12）：页面渲染时按 `page:<n>;rect:...` 在页面上绘制半透明高亮，与页面共用同一 `ctm` 故缩放/旋转自动对齐；`C-c C-h` 手动刷新；新增开关 `seshat-reader-annotation-highlight-enabled`。
- 阅读器**跨页衔接**（M12）：翻页时保留上一页最后一行作为上下文（新增 `seshat-reader-page-join-lines`，默认 1，设 0 关闭）；向下翻页落点为「上页末行可见 + 新页顶部紧接」，向上翻页落点为上一页底部，与 `fit-to-height` 等整页操作分别处理。
- `seshat:` 链接**补全与导出**（M12）：注册 `:complete`（候选来自 `seshat-reader-annotation-roots` 下的书库文件，当前文档优先）与 `:export`（导出为「文件名 第 N 页」可读文本，不输出裸协议串）。
- 摘录**按位置插入**（M12）：新增 `seshat-reader-reference-insert-position`（`end-of-file` / `headline` / `point`），默认仍是文件末尾；`headline` 模式插到光标所在 headline 子树末尾（`featurep 'org` 且 `derived-mode-p 'org-mode` 双守卫）。
- 阅读器 C 模块**三个高亮导出函数**（M12）：`seshat-reader-dyn--add-highlight` / `--clear-highlights` / `--refresh-highlights`。
- 阅读器框选松手后闪现选区高亮（`seshat-reader-select-flash-duration` 默认 2 秒，0 关闭），建批注后转为持久高亮。

### 变更

- 状态端点改以 uid 为键（M7，B4）：`GET|PUT /api/progress/{uid}`、`GET /api/annotations?uid=`，批注写入按 uid 关联；`reading_progress` / `annotations` 在 v7 迁移中重建（`DROP` + 按 uid 新建，见「破坏性」）。
- WebDAV 写路径接入登记钩子（M7.4）：写钩子链新增 registry 登记调用，第三方 PUT/MOVE 后同样进 `resources`；FTS 索引**仍只覆盖笔记根**（`roots[0]`），书库根不进全文索引。
- `emacs/seshat-reader`：完成自研化改名（`reader` → `seshat-reader`），feature / 符号 / 文件名 / C 模块可见名统一为 `seshat-reader-*` 与 `seshat-render-core`；构建产物改为 `seshat-render-core.so` + `seshat-reader-autoloads.el`。
- `emacs/seshat-reader/seshat-reader-select.el`：引用随之更新（鼠标选区取文功能不变）。
- 验证：`make clean && make all` 通过；独立 Emacs 进程文本提取与 `pdftotext` 归一化后逐字一致；断言 7/7。

- Android 端构建源切换为国内镜像：`android/settings.gradle.kts` 的插件与依赖仓库改为阿里云镜像优先（官方源保留兜底），`gradle/wrapper/gradle-wrapper.properties` 的 Gradle 分发包仍为官方源（`services.gradle.org`），仅版本 `8.11 → 8.14.5`；AGP `8.5.2 → 8.13.2`；依赖版本与构建语义不变，已验证依赖解析无国外源请求、`assembleDebug` 构建通过。
- M11.5 收尾修复：`reader-explain` 改用解释 prompt（不再误用翻译模板）、`gt-posframe-pop-render-timeout` 由 30s 调至 90s（展示时长与引擎请求超时对齐；注意 `gt-posframe-pop-render-timeout` 为**全局**变量，调至 90 秒后影响所有 gt posframe（word/sentence/paragraph/reader 等），不只是阅读器解释）、用户配置 `gt-htt-proxy` 拼写修正为 `gt-http-proxy`。
- **破坏性**：`seshat-reader-translate-render` 默认值由 `pop` 改为 `sidebar`——译文/解释默认渲染到底部面板（`seshat-reader-sidebar`）而非 posframe，避免 posframe 抢焦点与自动消失；可用 defcustom 切回 `pop`（posframe）/`pin`，或设 `seshat-reader-sidebar-enabled` 为 `nil` 退回旧行为。
- `emacs/seshat-reader/Makefile`：新增可选 ETAF 依赖探测（`ETAF_ROOT ?= $(HOME)/WorkSpace/emacs-taf`），存在时把四仓库根与各自 `lisp/` 加入 `-L`；不存在时从编译与 checkdoc 列表中剔除 `seshat-reader-etaf.el`（`etaf-view` 为宏，编译期必须有 etaf-ui）。
- `emacs/seshat-reader/` 包内新增 3 个自研扩展模块（`seshat-reader-reference.el` / `seshat-reader-sidebar.el` / `seshat-reader-etaf.el`），`VENDORED.md` 自研扩展表同步。
- **阅读器面板渲染重构（M11.10，2026-10-18）**：译文/解释改为**面板内只读 Markdown 文本 buffer 完整渲染**——gt 只渲染到隐藏中转 buffer ` *Seshat gt*`（`:window-config` = `display-buffer-no-window` + `allow-no-window`），`:then` 回调取纯文本写入展示 buffer，以 `gfm-view-mode` → `markdown-view-mode` → `text-mode` 降级链显示（原生折行/滚动/复制/isearch）；`header-line` 显示「Seshat 译文」/「Seshat 解释」，面板内 `q`（关面板）/`C-c C-s`（存为批注）改由 minor mode `seshat-reader-translate-panel-mode` 承载。**删除**「来源：第 N 页」行与自绘「q 关闭」提示；`seshat-reader-translate-render` 的 `sidebar` 语义随之更新（面板内 Markdown 文本 buffer，非 ETAF 排版），`pop`/`pin` 仍为 posframe 回退。`seshat-reader-sidebar-translate-buffer-name` 改为**展示 buffer** 名（不再作 gt `:name` 与捕获守卫）。**ETAF 渲染层收敛为批注卡片**：译文排版组件树与 `seshat-reader-etaf-render-translate` 删除（`seshat-reader-etaf.el` 929 → 690 行），ETAF 只渲染批注列表 + 分页。
- **破坏性**（M11.13）：删除 `seshat-reader-annotation-page-size` 与批注列表的 `]` / `[` 翻页键；用户配置中引用该变量不再生效。`seshat-reader-translate-show-source` 默认值由 `nil` 改为 `t`（面板默认显示原文，内容更高）。
- 状态 API 由文档标识改为 uid（Android，M9.2 A 批，2026-10-18）：`GET|PUT /api/progress/{uid}`、`GET /api/annotations?uid=`、`POST /api/annotations` 请求体字段，以及 `RestClient` / `SyncManager` 的参数名与 DTO 字段统一改名（`@SerialName("uid")`，无残留旧字段）；本地进度/批注的 Store 键在「有 uid」时改用 uid。
- 连通性探测探针改为 `GET /api/roots`（Android，M9.2 A 批，2026-10-18）：原探针打批注端点并带自造的文档标识，M7 起批注按 uid 查询且要求 uid 已登记，客户端没有可用的已登记 uid，导致对 M7 服务端**恒失败**；`/api/roots` 无入参、只读、不写数据，200 即证明地址可达 + 令牌有效。旧服务端（无该路由）返回 404 → `ServerError(404)`，设置页应提示版本可能过旧。
- 笔记 tab 改为「笔记库 + 渲染阅读」（Android，M10.7，2026-10-18）：原 B4 的「**单** org 文件 TODO 树」形态改为「多文件笔记库列表 + 渲染阅读页」——列表按文件列举所有 `.org`/`.md`，点行进渲染页；**笔记搜索改为只搜标题与标签**（不再搜正文，外部目录全文搜索成本高）；`Agenda` 段改为**跨文件 TODO 汇总**（所有来源 org 文件的条目并集，按最早日期升序）并**降级为只读**（点击提示，切 TODO 需在笔记内编辑或用 `GtdActivity`）；笔记段的「同步单个 org 文件」按钮随之移除（上传入口只剩 `GtdActivity`），`ui/NotesEditActivity` 暂保留但当前无调用方。
- `ResourceIndex` 改为线程安全（Android，M9.2 B 批，2026-10-19）：所有 public 方法加 `@Synchronized`，`all()` / `alive()` / `entriesInRoot()` / `dirtyEntries()` **返回副本**（调用方可在锁外安全遍历）；新增 `dirtyEntries(root)` / `applyMetadata(updates)`（批量写 `blob`/`size`/`mtime` 并清 `dirty`）。锁是**实例锁**，故由 `SyncHolder` 保证全进程唯一；仍假定单进程（`SharedPreferences` 跨进程不安全）。
- 书架条目结构扩展（Android，M9.2 B 批，2026-10-19）：`BookItem` 新增 `uid`（服务端身份，null = 纯本地）、`isDownloaded`（远端未下载为 false）、`remote: RemoteBook?`（远端来源）；`BookLibrary.load()` 接受可选的远端清单来源，本地扫描结果与远端清单**按文件名**对齐合并，`null` 即退回 M9.2 之前的纯本地书架行为。
- 阅读器工具栏重排（Android，M10.8，2026-10-20）：EPUB 顶栏改为「`←` 返回 / 章节标题 / 批注 / 目录 / 设置」、底栏只留章节 `SeekBar` + 可点的「第 n/N 章」；PDF 顶栏「`←` 返回 / 文件名 / 手写 / 批注 / 目录 / 设置」、底栏页 `SeekBar` + 可点页码。**删除** EPUB 的 `prevChapterButton` / `nextChapterButton` 与 PDF 的 `pdfPrevPageButton` / `pdfNextPageButton`（翻页由 tap 分区与 `SeekBar` 承担）；「设置」跳既有 `SettingsActivity`（阅读内浮层设置面板未做，记 tech-debt）。**一处偏离原计划**：EPUB 原底栏「批注」按钮未删除而是**移到顶栏**——`addAnnotationFromSelection()` 只有这一个入口，删掉会让批注能力消失。
- 书架底部三按钮并为单一「导入书籍」（Android，M10.8，2026-10-20）：`fragment_reader.xml` 的导入 / 选择 EPUB / 打开示例三按钮收敛为一个 `@string/shelf_import` 入口，`importButton` → `pickImport.launch(arrayOf("*/*"))`，由 `BookImporter.detectType` 按扩展名自动识别 epub / pdf（mobi 提示需转换）；`ReaderFragment` 删除 `pickEpub`（直接打开不进库）与 `openSampleEpub()`，示例书改为 `seedSampleIfEmptyThenRefresh()`——书籍目录为空时把 `assets/sample.epub` 复制进去（**不打开**），在 `scanExecutor` 上执行、完成后回主线程刷新书架。
- 新增依赖 `com.tom-roush:pdfbox-android:2.0.27.0`（Android，M10.8，2026-10-20）：为读 PDF 真目录（`/Outlines`）与单页文本提取，在「零新增依赖」的强约束下**破例**引入（用户 2026-10-20 明确授权的唯一例外，理由与约束见 `openspec/decisions.md`）。APK 体积约 +10 MB；`PDFBoxResourceLoader.init(applicationContext)` 在 `PdfReaderActivity.onCreate` 调用一次（早于任何 `PDDocument` 使用），库的使用限定在 `reader/` 包内。
- 两个阅读器的目录入口由 `AlertDialog.setSingleChoiceItems` 改为左侧树形抽屉（Android，M10.9，2026-10-20）：EPUB `showToc()` 与 PDF `showPdfToc()` 均改为打开 `TocDrawer`（PDF 侧仍在 `ioExecutor` 上读书签树，读完再弹；已打开时再点「目录」则关闭）；原扁平列表与「`pageIndex < 0` 的书签点击只关对话框」的交互取消，改为可折叠层级、打开即展开当前项祖先链并滚动定位。`reader/PdfTocEntries.kt` 与 `reader/TocItemText.kt` 因此**已无生产代码引用**（`PdfTocEntriesTest` / `TocItemTextTest` 仍在跑），留待清理，见 `openspec/tech-debt.md`。
- 阅读器**进入即沉浸**（Android，M10.9 追加，`c4a76d3`，2026-10-20）：打开 EPUB / PDF 阅读器时默认隐藏顶部与底部两块浮层，阅读区铺满全屏（上下 padding 为 0）；点屏幕中央调出浮层、再点收起，退出阅读用系统返回键。仅隐藏应用内浮层，**系统状态栏仍可见**（未做系统栏 immersive）。实测（`24091RPADC` / Android 16）：进入时 `uiautomator dump` 无任何工具栏文本、WebView bounds `[0,0][3200,2136]`、无满宽暗带；点中央后顶栏 `0..240`、底栏 `1931..2107`、WebView 变 `[0,241][3200,2136]`；连续 4 次显隐 WebView top 在 `241 ↔ 0` 之间无漂移。
- 手写参数面板改为**屏幕右侧竖排浮动条**（Android，M10.9 追加，`c4a76d3`，2026-10-20）：原横排在 PDF 顶部浮层内的「颜色 / 粗细 / 笔型」三行 `inkPanel` 改为右侧竖排浮条（宽 96dp，`end|center_vertical`），仅手写模式显示，自上而下为 `✕`（退出手写）/ 撤销 / 清空 / 6 色 / 3 档粗细 / 3 种笔型；面板不属于顶部浮层，不影响顶部栏高度与阅读区 padding。实测面板 bounds `[2936,520][3200,1615]`（264px = 96dp × 2.75，纵向居中），点 `✕` 后手写控件全部消失。**已知**：该条覆盖正文右缘 264px（手写模式下不可书写，未做右侧留白），退出手写后首次单击不弹工具栏，见 `openspec/tech-debt.md`。

- 阅读器目录面板不再用 `pop-to-buffer`（M12），改由 `seshat-reader-sidebar-show` 承载，受 `seshat-reader-sidebar-enabled` / `-position` 管辖。
- `seshat-reader--set-window-vscroll` 的像素路径不再对已按像素传入的值再乘一次 `pixel-per-col`（M12；此前仅因 clamp 而「看起来正确」）。
- 阅读器翻页/跳页命令现在会显式设置纵向落点（M12）：此前部分命令不改 vscroll，依赖 C 侧重置。
- 阅读器目录面板行首星号改为零宽显示（保留 outline 折叠能力），缩进收窄；`f` 等单键在 evil 下由包内补绑，不再依赖用户配置。

### 破坏性

- **`seshat-reader-sidebar-position` 默认值由 `below-selected` 改为 `right`**（M12，破坏性变更）：升级后批注/译文面板出现在右侧而非底部。恢复旧观感：在配置中设 `(setq seshat-reader-sidebar-position 'below-selected)`；`left` / `right` 为新增取值，`below-selected` / `at-bottom` 仍然可用。

- **状态 API 不再接受 `document_id`**（M7）：改用 uid——形态非法返回 `400 invalid_uid`，uid 未登记或已墓碑返回 `404 unknown_uid`。服务端尚未部署、无存量数据，故 v7 迁移直接 `DROP` 重建 `reading_progress` / `annotations`；迁移前 `preMigrationChecks[7]` 对两表做 `COUNT(*)` 防御，任一非空即中止（整条迁移回滚、`user_version` 保持 v6）。
- **Emacs 客户端必须同步升级**（M7）：旧客户端仍发 `document_id`，批注/阅读进度不再可用；升级后 `uid` 经 `GET /api/resolve` 首次解析并缓存。Android 端的 uid 适配留待后续里程碑。

### 修复

- **安全边界收紧（M7 修复轮）**：`.git` 与点路径（任一以 `.` 开头的段）在 **REST 与 WebDAV 两侧**一律拒绝（REST `400 invalid_argument`，WebDAV `403 Forbidden`，两侧判定同口径），堵住 `.git/config` 泄露 remote URL 与「写穿版本库」的路径；**符号链接不跟随**——登记/重扫只收普通文件，REST 读端点对软链返回 `404`、写端点返回 `400`，父目录经软链越出根同样 `400`；`PUT` 的 `If-Match` 改为**原子条件写**（读 ETag/比较/落盘/commit 在同一临界区，并发同 ETag 只有一个成功）；**空 ETag 永不匹配**（不再退化为无条件写）；`If-None-Match: *` 的「已存在」判据改为「登记表存活 ∨ 磁盘存在」，覆盖登记与磁盘不一致的两种状态。
- 修复 rescan 把「处理失败」误判为「已删除」（M7 修复轮）：`registry.scanRoot` 的 `seen` 集合改为「磁盘上确认存在即计入」，与后续读元数据/登记是否成功解耦——修复前一次读取失败会让 Rescan 为该文件写墓碑并产生 `delete` 事件，把可重试的失败放大成客户端可见的「文件被删除」；失败只计入 `failed` 计数，由下一轮幂等补齐。
- 修复目录删除误伤同前缀资源（M7 修复轮）：子树收敛从 LIKE 前缀改为**路径段边界**判定（`path` 等于目标，或其前缀恰为「目标 + `/`」），删除 `a/b` 不再命中 `a/bc`、`a/b-备份`。同时 `GET /api/resources?prefix=` 的 `ListResources` 一并改为大小写敏感的精确段边界匹配，`%`/`_` 不再作为通配符生效（客户端无需再二次过滤）。
- 修复 `GET /api/files` 大文件全量读入内存（M7 修复轮）：改用 `http.ServeContent` **流式**输出，ETag 逐块哈希计算（内存 O(1)）；`Range`/`If-None-Match`/`If-Modified-Since`/`If-Range` 全部交给标准语义处理。**行为变化**：不可满足的 `Range` 仍返回 `416` + `Content-Range: bytes */<size>`，但响应体不再是 JSON 错误结构（由标准内容服务产生纯文本），代码不再产生 `range_not_satisfiable` 错误码（文档已同步）。
- 修复单份文档引用刷新可阻塞数据库（M7 修复轮）：新增 `maxRefsPerDocument = 2000` 上限，超出部分按首次出现顺序**截断并记日志**（写操作仍然成功，不影响文档落盘与 commit），避免超大引用集在一次请求内锁住 DB。
- Android 设置页「保存」不再被服务端校验阻断（M10.6 B1）：服务端改为**可选配置**——`SettingsValidator` 新增 `UrlValidation.Empty` 作为合法状态（替代原 `UrlError.EMPTY` 错误），地址留空时仍可保存远程目录/字号/翻页模式等本地偏好；令牌可单独保存（新增 `SettingsStore.saveTokenOnly()`，仍走加密通道）。同时修复两处连带问题：① 地址留空时点「测试连接」会抛 `ClassCastException` 崩溃（`as UrlValidation.Ok` 强转），现改为三态分支并提示「请先填写服务端地址」；② 测试 helper 对 sealed 类型 `when` 非穷尽。EPUB 竖向连续滚动模式的**章节标题滞后**修复：当前章改取「覆盖视口中心的那一项」（`ScrollProgressMath.visibleCenterPosition`），章内偏移改取中心项自身顶部滚出量（`-centerView.top`），不再复用首项锚点。单测 249 → 260（`SettingsValidatorTest` +2、`SettingsStoreTest` +3、`ScrollProgressMathTest` +6）。另：真机验证暴露并修复「令牌校验把空值当硬错误」——`save()` 现只拦截 `ILLEGAL_CHARS`（会让请求头构造崩溃的非法字符），`EMPTY` 不再阻断保存；实测地址留空 + 无令牌时可成功保存翻页模式，令牌含空格仍被拦。
- Android 设置页安全加固（M9.1，安全审查发现 3 项 blocking）：① 令牌在加密存储不可用时**不再降级写入明文** `SharedPreferences`——`SecurePrefs` 新增 `putSecret()`（不可加密即拒绝写入并返回 false），设置页在 `isEncrypted=false` 或解密异常时禁用保存并显示常驻告警；② 新增 `res/xml/backup_rules.xml` 与 `data_extraction_rules.xml`，把 `seshat_sync_secure.xml` / `seshat_sync.xml` 排除出 Auto Backup 与设备迁移（避免明文令牌上云、密文换机后 KEK 失效）；③ 解密异常不再导致设置页崩溃，改为可读告警 + 「重置本地配置」自救入口；④ 服务端地址校验**仅接受 https**、拒绝 userinfo（`https://real.com@evil.com` 类钓鱼）、拒绝查询参数与锚点、限制长度 2048 与端口范围；⑤ 新增「清除访问令牌」入口；⑥ 令牌输入框禁用 Autofill 与实例状态保存、设置页启用 `FLAG_SECURE`、离开页面清空输入框。新增/调整 JVM 单测至 179 例。另在复审后进一步移除 `SettingsStore.writeSecret` 的默认值（消除「漏传即静默写明文」的 fail-open 分支）、让 `clearAuthToken()` 返回真实结果并由 UI 提示，并修正文档中「重置本地配置可修复加密存储」的错误承诺。
- 批注列表在 ETAF 已挂载时不再 `erase-buffer`（改为交给渲染层增量刷新）：此前任何刷新路径（含 uuid 删除）都会触发 `etaf-runtime-flush` 报 `Args out of range: 20, 20`，并整块降级为纯文本渲染。
- 译文面板「来源：第 x 页」重复：正文管线渲染前剔除所有以 `来源：` 开头的行（gt 提取失败时会回退整个 buffer-string，把头部行与正文一起带出）；原文展开区不过滤，保持忠实摘录。**M11.10（2026-10-18）起该过滤器与「来源」行一并从代码中删除**——面板 Markdown 路径不再生成「来源」行，也不再自绘「q 关闭」提示（键位由 minor mode `seshat-reader-translate-panel-mode` 承载）。

- **安全（S1/S2，M7 安全复审，2026-10-18）**：WebDAV 出口增加符号链接守卫——新增 `internal/webdav/symlink.go` 的 `symlinkGuardFS` 并接入 `/dav/` 与 `/public/` 两个出口（包装顺序 `webdav.Dir → extWhitelistFS → readOnlyFS → symlinkGuardFS → dotPathFS → versionedFS`），与 REST 同口径、实际更严：请求路径的父链或目标自身含软链一律拒绝（`os.ErrPermission`，PROPFIND 中该项被静默跳过）。`GET /api/files` 对危险扩展名（`.html`/`.htm`/`.xhtml`/`.svg`/`.xml`/`.xsl`/`.js`/`.mjs`）强制下载（`Content-Type: application/octet-stream` + `Content-Disposition: attachment`），并对**所有**下载加 `X-Content-Type-Options: nosniff`；Web UI 首页与 `/static/` 加 `nosniff` + `X-Frame-Options: DENY` + CSP（`default-src 'self'`）。**残余**：`/api/` 的其它响应（JSON 端点与错误响应）仍无安全头，HSTS 仍由反代负责（见 `docs/security.md` §8.7、§8.8）。
- 修复：`If-Match` 与 `If-None-Match` 同时出现时**两者都校验**（此前只校验 `If-Match`，`If-None-Match` 被静默忽略）——任一前提不满足即 `412 etag_mismatch` 且内容不变；`If-Match` 已匹配与 `If-None-Match: *` 的组合因此恒为 412（两个前提不可同时成立），这是有意为之。
- 修复进度推送因 `updated_at` 小数秒被服务端拒绝（Android，M9.2 A 批，2026-10-18）：服务端用 `time.RFC3339` 解析，不接受小数秒，客户端此前序列化带毫秒，导致 `PUT /api/progress` 一律 `400`；现统一**截断到秒**。
- 阅读器进度推送由「每次翻页」改为「`onStop` 一次 + 同值跳过」（M9.2 A 批，2026-10-18）：每页推送会让请求数随翻页线性增长并可能把服务端写爆，改为离开阅读器时推送一次；`lastPushedPosition` 的同值跳过只是防抖，不是严格节流。
- `SyncEngine` 改为分段批量落盘（M9.2 A 批，2026-10-18）：create/update 先累积到内存，遇到 rename/delete 或批次结束才一次 `upsertAll`，把「N 条事件 N 次全量重写」的 O(N²) 写放大压成「每段一次」；rename/delete 前强制 flush 以保证事件顺序语义。
- 修复 EPUB 双击缩放误切换工具栏（M10.6 B2）：单击改为 250ms 延迟切换，双击第二击取消待执行切换，左右各 30% 边缘不响应，双击只缩放不切换浮层。
- 修复 EPUB 浮层化后中心章判定偏移（M10.6 B2）：竖向模式中心章改取可见区中心，原 `height/2` 在新增 padding 下偏移约 26dp。
- 修复 PDF 页码/进度指示在布局型跳转后不同步（M10.6 B2）：`jumpToPage` 后的 `scrollToPosition` 可能不触发滚动回调，改用 `doOnNextLayout` 走既有更新链路。
- 修复笔记渲染页「编辑源码」保存后 toolbar 标题仍是旧值（M10.7 真机验收，2026-10-19）：`NoteViewActivity.reload()` 重渲染后只换了正文、标题栏沿用打开时的 `EXTRA_TITLE`。现改为在同一个后台任务里用**新文本**算出首个 heading（`NoteScanner.firstHeading`），渲染成功后同步字段 `currentTitle` 与 toolbar 标题；取不到 heading（文件被清空/无 heading）时保留原标题不置空，`EXTRA_TITLE` 本身不回写（`intentForFile`/`intentForUri` 的调用约定不变）。
- 修复笔记列表只显示 denote 文件名里的标签、忽略 org `#+FILETAGS:`（M10.7 真机验收，2026-10-19）：`sample.org` 带 `#+FILETAGS: :notes:` 但列表行 meta 只有 `ORG · 时间`。`NoteScanner` 新增 `fileTags(text)`（行首匹配 `#+FILETAGS:`，允许前导空白与大小写差异，去首尾 `:` 后按 `:` 分割并过滤空串），标签合并改为「denote 文件名标签优先，denote 缺失或为空时回退 FILETAGS」。**IO 影响**：只在「denote 未命中」（原本就要读内容找 heading）或「denote 命中但无标签」（新增的一次读取）时读文件，有标签的 denote 文件仍然零读取；SAF 外部目录同理。新增 4 例单测（`fileTags` 三例 + 「denote 无标签回退 FILETAGS」一例），单测 562 → 566。
- 修复阅读器浮层隐藏后底部仍留白（Android，M10.8，2026-10-20）：M10.6 B2 的 `applyChromePadding()` 是**一次性**的（只在高度变化时把浮层高度写进阅读区 padding），`toggleChrome()` 只切可见性、**不回收** padding，沉浸阅读时底部恒留一条与浮层等高的空白。现改为两侧各一个 `applyContentPadding()`，按「浮层是否 `VISIBLE` + 当前 height」实时计算上下 padding（隐藏即归零），配 `appliedTopPadding` / `appliedBottomPadding`（EPUB 另加 `appliedContent`）幂等闸只在值真变时才写，避免 `setPadding` → 重布局打断滚动锚点；布局监听改为常驻，字体缩放 / 旋转 / insets 变化都会重算。EPUB 侧在 padding 变化后主动 `reportVisibleChapter()`（padding 变化不派发 `onScrolled`，不重算会让持久化的章内偏移漂移）。
- 修复 EPUB2 旧书无封面（Android，M10.8，2026-10-20）：原封面只认 EPUB3 `properties="cover-image"`，`<meta name="cover">` 不识别，存量 EPUB2 在书架上只剩灰占位。现 `EpubParser.pickCoverHref` 三级回退（EPUB3 → EPUB2 `<meta name="cover">` → manifest 首个 `image/*`），仍无封面时卡片叠书名首字占位。详见 `docs/android.md` §6.5。

- 修复阅读器**目录中文标题显示为 `\346\226\207` 八进制转义**（M12）：C 侧 outline 标题改用 `decode-coding-string 'utf-8` 解码（非法字节保留 raw byte、不中断开书），imenu 路径同步修复。
- 修复阅读器**目录面板切换文档后内容不刷新**（M12）：改为每次显示都按当前文档重建，且先校验再重建（无目录时不清空已有内容）。
- 修复 `seshat-reader-dyn--text-in-rect` / `--add-highlight` 对**逆序角点**（如 `x0 > x1`）的误拒（M12）：`fz_is_valid_rect` 要求 `x0 <= x1`，原实现在归一化之前校验；现改为先归一化再校验。
- 修复 C 模块**换文档/关文档时泄漏整份 `DocPage` 数组与每页 mutex**（M12）：`free_doc_pages` 此前零调用点，现接入 `free_doc_state`（在 drop MuPDF 上下文之前）。
- 修复 `seshat:` 链接对**尾部裸 `#`** 解析出空串 location（M12）：现归一为 `nil`。
- 修阅读器默认不居中与页面裁切（M12 回归）：`window-size-change-functions` 钩子此前把 frame 当 window 传导致居中从不重算；跨页衔接（strip 行）在 `fit-to-height` 下会裁切页面，现默认关闭（`seshat-reader-page-join-lines` 默认 0）
- 阅读器退出文档后目录面板窗口残留（现随 buffer 关闭一并关闭并清空内容）

## [0.2.0] - 2026-10-12

### 变更（Breaking Change）

项目品牌由 `notes` 更名为 `Seshat`。本次为**破坏性变更**，升级前务必按 [`docs/migration-seshat.md`](docs/migration-seshat.md) 执行迁移；改名的方案、命名映射与用户裁决见 [`openspec/completed/seshat-rename.md`](openspec/completed/seshat-rename.md)。

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
- **Android GTD 数据源统一**（M10.6 B4）：`GtdActivity` 由 `filesDir/sample.org` 改为 `filesDir/notes/sample.org`（与 Notes 列表同源，消除双副本分叉）；旧文件保留不删。Notes tab 的 Agenda 段成为主入口，`fragment_notes.xml` 移除 `openGtdButton`，`GtdActivity` 保留为可独立启动的 Activity（字符串资源 `main_open_gtd` 保留）。
- **Android 同步实现去重**（M10.6 B4）：GTD 与 Notes 的 org 上传合并为 `gtd/NotesSync`，Toast 文案与线程结构不变（Notes 侧成功文案为「已上传到 <路径>（HTTP <码>）」）。

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
