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

### 破坏性

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

## [0.2.0] - 2026-10-12

### 变更（Breaking Change）

项目品牌由 `notes` 更名为 `Seshat`。本次为**破坏性变更**，升级前务必按 [`docs/migration-seshat.md`](docs/migration-seshat.md) 执行迁移；改名的方案、命名映射与用户裁决见 [`openspec/active/seshat-rename.md`](openspec/active/seshat-rename.md)。

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
