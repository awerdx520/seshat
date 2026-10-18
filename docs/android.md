# Android 客户端结构

本文描述 Android 客户端（`android/`）的 UI 结构与模块边界；构建与验证命令见第 8 节。

## 1. 三区骨架（M9.1）

应用采用**单 Activity Shell + Fragment 内容区**结构：

| 区域 | 组件 | 说明 |
|---|---|---|
| 顶部工具栏 | `MaterialToolbar`（`@id/mainToolbar`） | 标题随 tab 变化（笔记 / 阅读），溢出菜单提供「设置」 |
| 内容区 | `FragmentContainerView`（`@id/fragmentContainer`） | 承载 `NotesFragment`（默认）与 `ReaderFragment` |
| 底部 | `BottomNavigationView`（`@id/bottomNav`） | 双 tab：笔记（`nav_notes`）/ 阅读（`nav_reader`），仅文字标签 |

- 宿主：`MainActivity`（`com.seshat.app`）。tab 选择经 `ui/MainTab` 编解码后存入 `savedInstanceState`，进程重建后恢复。
- tab 切换用 `FragmentTransaction.show/hide`，两个 Fragment 只创建一次，切换保留各自视图状态。
- 两个 Fragment 首次创建时用 `commitNow()` 添加，保证 `findFragmentByTag` 立即可用（不依赖 fragment-ktx 扩展）。

## 2. tab 与功能归属

| tab | Fragment | 承载内容 |
|---|---|---|
| 笔记 | `ui/NotesFragment` | M9.1 仅有「打开 GTD」入口（`gtd/GtdActivity`）；orgzly 风格列表 / 搜索 / 编辑由 M9.3 接入 |
| 阅读 | `ui/ReaderFragment` | 书架网格（M10.6 B3：扫描 `filesDir/books/`、过滤/排序、点书进阅读器，见 §7）+ 底部 3 个入口：导入书籍、选择 EPUB、示例 EPUB（PDF 由书架点击打开） |

阅读器（`reader/EpubReaderActivity`、`reader/PdfReaderActivity`）与 GTD（`gtd/GtdActivity`）仍是**独立全屏 Activity**，由 Fragment 内的入口启动——沉浸阅读不占内容区，且保证既有实现零改动。

## 3. 设置页（M9.1 起，M9.2 扩展到 8 项）

`settings/SettingsActivity` 承载全部配置：

| # | 设置项 | 存储 | 生效时机 |
|---|---|---|---|
| 1 | 服务端地址 | `SecurePrefs.KEY_SERVER_URL`（加密 prefs） | 下次请求 |
| 2 | 访问令牌 | `SecurePrefs.KEY_AUTH_TOKEN`（加密、不回填明文） | 下次请求 |
| 3 | WebDAV 远程目录 | `AppPreferences` 的 `remote_dir` | 下次同步 |
| 4 | 主题（跟随系统 / 浅色 / 深色） | `app_theme` | **立即**（`SeshatApp` 里 `AppCompatDelegate.setDefaultNightMode`，Activity 自动重建） |
| 5 | 正文字号（80–200%，**仅 EPUB 生效**） | `reader_text_zoom` | 下次打开阅读器 |
| 6 | 翻页模式（横向翻页 / 竖向连续滚动） | `reader_page_mode` | 下次打开阅读器 |
| 7 | 连通性测试 | 无存储 | 按下即测（`GET /api/roots`——无入参、只读，200 即证明「地址可达 + 令牌有效」。M7 起批注端点按 uid 查询且要求 uid 已登记，客户端没有可用的已登记 uid，故不再用批注端点探测；未升级到 M7 的旧服务端没有该路由，返回 404 → `ServerError(404)`，设置页应提示「服务端版本可能过旧」，见 §10） |
| 8 | 关于 | 无存储 | 静态（版本号 + 配置状态） |

- 存储**分两层**：机密与同步配置走 `SecurePrefs`（EncryptedSharedPreferences，见 `docs/security.md` §7）；
  远程目录 / 主题 / 字号 / 翻页模式走 `settings/AppPreferences`（普通 `seshat_app_prefs.xml`，不加密、参与系统备份）。
  因此**加密存储不可用时，主题与阅读偏好仍可用**。
- 服务端地址**仅接受 https**；带 userinfo（`https://real.com@evil.com`）、查询参数或锚点的地址会被拒绝，长度上限 2048。
- **服务端是可选配置**：地址留空即「仅本地使用」，此时仍可保存远程目录/字号/翻页模式等本地偏好；令牌可单独保存（`SettingsStore.saveTokenOnly`）。清空地址**不会**删除已保存的服务端配置（要删除请用「重置本地配置」）。地址留空时「测试连接」会提示先填地址。
- 加密存储不可用时保存被禁用并显示常驻告警；可通过「重置本地配置」清除后重试（若反复出现需在系统设置中清除应用数据，见 `openspec/tech-debt.md`）。
- 提供「清除访问令牌」入口，用于设备外借或令牌疑似泄露时撤销本机凭据。
- 设置页启用 `FLAG_SECURE`（禁止截屏/最近任务缩略图），令牌输入框禁用 Autofill 与实例状态保存。

## 4. 模块边界

| 包 | 职责 | 约束 |
|---|---|---|
| `ui/` | Shell 与导航 | 只做承载，不含业务逻辑 |
| `settings/` | 配置校验与持久化 | 不做网络 |
| `sync/` | 传输层（REST / WebDAV）与安全存储 | 被 `settings` 与阅读器复用 |
| `reader/` | epub / pdf 阅读与本地进度、批注 | 由 `ReaderFragment` 启动 |
| `gtd/` | org 解析、过滤、编辑与 GTD 视图 | 由 `NotesFragment` 启动 |
| `importer/` | 书籍导入 | 由 `ReaderFragment` 调用 |

## 5. 阅读器渲染管线（M9.2）

两个阅读器都支持「横向翻页（吸附）」与「竖向连续滚动（页/章间零间隙）」，由 `reader_page_mode` 切换，**下次打开阅读器生效**。

### 5.1 PDF（`reader/PdfReaderActivity` + `PdfPageAdapter`）

| 项 | 实现 |
|---|---|
| 容器 | 单一 `RecyclerView`：横向 = `LinearLayoutManager(HORIZONTAL)` + `PagerSnapHelper`；竖向 = 竖向 `LinearLayoutManager`，页间零间隙 |
| 渲染 | 单线程 `Executor`（`PdfRenderer` 非线程安全，必须串行）+ 白色占位；`shutdownNow()` 在 `onDestroy` |
| 缓存 | `LruCache<Int, Bitmap>`，上限 `maxMemory/8`；目标页 ±2 预取 |
| 进度 | `ScrollProgressMath` 把「首个可见项 + 顶部偏移」换算为页码，两种模式共用同一 key |
| 手写批注（M10.5） | `InkOverlayView` 叠在页面 `ImageView` 之上；笔迹以**归一化坐标 0..1**（相对 FIT_CENTER 显示矩形）存于 `PdfInkStore`（键 `pdf_ink_<docId>`）；坐标换算走纯函数 `InkGeometry`（含 4 个数值示例的单测）；支持撤销上一笔、清除本页 |
| 交互模式（M10.5） | 「阅读 / 手写」双模式：手写时 `InkOverlayView` 拦截触摸并 `requestDisallowInterceptTouchEvent(true)`，浮层显示「上一页 / 下一页」保证仍可翻页 |
| 点击翻页与横屏（M10.5） | `GestureDetector` 三区点击（左 30% / 中 40% / 右 30%），`onInterceptTouchEvent` 恒返回 false 不吞滑动；横屏 + 横向模式下 `renderWidth` 按可用高度 × 首页宽高比（夹紧屏宽），浮层工具栏改为贴底半透明并加系统栏 insets |

### 5.2 EPUB（`reader/EpubReaderActivity` + `ChapterScrollAdapter`）

| 项 | 实现 |
|---|---|
| 容器 | 两套并存、按模式显示其一：`ViewPager2` + `ChapterFragment`（横向）/ `RecyclerView` + `ChapterScrollAdapter`（竖向） |
| 竖向 item | 每章一个 `WebView`，高度 = 内容高度（`onPageFinished` 后 JS 取 `scrollHeight` / `window.innerHeight`，按「视口物理高 / 视口 CSS 高」换算物理像素，与 viewport meta 无关）；`isNestedScrollingEnabled=false` |
| 复用 | **禁复用**：`setItemViewCacheSize(0)` + 逐 viewType `setMaxRecycledViews(i, 0)` + `onViewRecycled` 里 `destroy()` |
| 重锚 | 测量完成 → `notifyItemChanged` 等价的高度变化 → 若该章为当前可见章，用 `scrollToPositionWithOffset(pos, -offset)` 重锚，避免阅读位置漂移 |
| 进度 | 语义不变：`ReadingProgress(chapterIndex, scrollY)`，竖向经 `ScrollProgressMath` 换算 |
| 批注 | 横向取 `ChapterFragment` 选区；竖向取当前可见章 `WebView` 的选区，共用 `decodeJsString` |

## 6. 阅读器交互（M10.6 B2）

两个阅读器的浮层与导航交互统一到同一套语义。

- **工具栏显隐**：单击阅读区中央切换浮层显示/隐藏；左右各 30% 边缘不响应（横向模式下是翻页热区，也为将来 EPUB 翻页留位）。单击有 250ms 延迟——期间若按下第二击则取消待执行的切换，即**双击只缩放、不切换浮层**。
- **章节导航（EPUB）**：底部 `SeekBar` 粗粒度跳章（拖动中不跳，松手才跳）；点击标题栏章号打开输入框，输入章号直接跳转（非法输入只提示「章号无效」，不跳转）；「目录」按钮弹出章节列表，当前章高亮，点击任一项跳章并关闭对话框。目录**无层级**（nav/NCX 已扁平化）。
- **页导航（PDF）**：底部 `SeekBar` 松手跳页；点击页码打开输入框，输入页号跳转。PDF **无 TOC 数据源**，故不做目录。
- **浮层与阅读区**：阅读区全屏，浮层半透明叠加其上；阅读区 `clipToPadding = false`，底部 padding 取**浮层运行时高度**（首次布局后写入，浮层高度变化时跟随更新），因此页尾/章尾内容不被浮层遮挡。**已知副作用**：浮层隐藏后 padding 仍保留，沉浸阅读时底部留一条与浮层等高的空白（回收 padding 会触发滚动重布局抖动，故不做，见 `openspec/tech-debt.md`）。
- **已知限制**：EPUB 目录无层级（`TocEntry` 无 `depth`）；PDF 无 TOC；`SeekBar` 在章/页数很大时精度不足（一像素跨多项），故保留输入框兜底；窄屏下 4 个按钮（手写/撤销/清除/批注）文案可能截断。

## 7. 书架（M10.6 B3）

`ui/ReaderFragment` 由「4 个入口按钮」改为「过滤/排序条 + 封面网格 + 底部入口」；数据装配在 `reader/BookLibrary`，封面解码在 `reader/CoverCache`，过滤/排序/百分比等纯逻辑在 `reader/BookShelfLogic`（JVM 可测）。

| 项 | 实现 |
|---|---|
| 数据源 | 仅本地 `filesDir/books/`（`BookImporter` 的落点），只收 `.epub` / `.pdf`（扩展名忽略大小写）。扫描在后台**单线程 executor** 上执行，**首次进入较慢**——每本 EPUB 需整包 `readBytes()` + 解析 OPF，每本 PDF 需打开一次 `PdfRenderer` 取页数。损坏/加密的文件静默跳过，不影响整架 |
| 网格 | `GridLayoutManager`，列数按屏宽 dp：≥600dp → 4 列、≥400dp → 3 列、其余 → 2 列；每格为「封面 + 标题 + 作者 + 进度徽标」 |
| 进度徽标 | 百分比 = `current / totalCount`（EPUB 章节数、PDF 页数）；**0% 不显示徽标**。进度由 `ReadingProgressStore.all()` / `PdfProgressStore.loadAll()` 各取一次后按 `progressKey` 合并（遍历中反复调 Store 会重复扫 prefs） |
| 过滤 | 全部 / 未读（0%）/ 在读（1–99%）/ 已读（100%），判定在 `BookShelfLogic.matches` |
| 排序 | 最近阅读（进度 `updatedAt` 降序，无进度为 0）/ 书名 / 导入时间（`file.lastModified()` 降序），在 `BookShelfLogic.sort` |
| 封面缓存 | 内存 `LruCache<String, Bitmap>`（按 `byteCount` 计，上限 `Runtime.maxMemory() / 8`）+ 磁盘 `filesDir/covers/<key>.jpg`；同时把元数据（标题/作者/章节数/进度键）另存 `<key>.json`，下次扫描直接读缓存，**避免重复解析 EPUB 与重算内容哈希**。缓存键 = `文件名 + length + lastModified` 的 SHA-256 前 16 位 hex（`reader/CoverKeys`），文件一变即换键 |
| 封面来源 | EPUB：manifest 中带 `properties="cover-image"` 的项；PDF：渲染首页并按 `inSampleSize` 降采样后落盘 |
| 打开 | EPUB → `EpubReaderActivity`（不带 `EXTRA_UID`，进度键为**内容哈希** = SHA-256 前 16 字节共 32 位 hex，与阅读器 `effectiveKey = uid ?: docId` 的无 uid 分支一致）；PDF → `PdfReaderActivity`（`file://` uri 作键） |
| 示例书迁移 | `assets/sample.epub` 首次复制到 `filesDir/books/`；旧版 `filesDir/sample.epub` 保留不删，作回滚点。进度键是内容哈希，故迁移后同一本书的进度仍然可见 |

**已知限制**：

1. 有服务端 uid 登记过的书，书架按内容哈希查不到其 uid 键进度（徽标可能恒 0）。
2. PDF 用书架 `file://` 与 SAF `content://` 打开是**两套进度**，互不共享。
3. EPUB2 封面不支持：只认 EPUB3 的 `properties="cover-image"`，`<meta name="cover">` 不识别。
4. `covers/` 无自动清理：书籍删除后封面与元数据缓存滞留（无容量上限）。
5. 切 tab 不刷新书架：`show/hide` 不改变生命周期、`onResume` 不触发；从阅读器返回会刷新（`onResume` 里按需重扫）。

## 8. 构建与验证

```sh
cd android
./gradlew :app:assembleDebug        # L1：编译与打包
./gradlew :app:testDebugUnitTest    # L2：JVM 单测（无 androidTest）
```

L3（设备安装与交互验证）需要真机或 AVD；当前环境无可用设备与系统镜像，相关缺口见 `openspec/tech-debt.md`「Android L3 设备验证缺口」。

## 9. 文档标识演进（M7 之后）

M7 把服务端的文档身份从「客户端自定字符串」改成「服务端权威 uid」，Android 侧尚未跟进，形成了明确的**已知不一致**：

- **现状**：`reader/EpubParser.documentIdOf` 用 **epub 字节内容的 SHA-256 前 16 字节**（32 位十六进制）作文档 id；PDF 侧则直接用文件 `uri.toString()` 作 docId。本地进度与批注以它为键（`PdfInkStore` 的 `pdf_ink_<docId>`、`PdfAnnotationStore` 的 `pdf_annotations_*` 等）。
- **服务端期望**：uid 是 26 位 Crockford Base32（`crypto/rand` 生成，客户端不得自行生成），两者形态与来源都不同——**内容哈希 / 本地 URI ≠ 服务端 uid**。
- **当前后果**：M7 起状态 API（`/api/progress/{uid}`、`/api/annotations?uid=`、`POST /api/annotations`）只接受 uid。Android 现版本若把 `documentId` 当 uid 发送，epub 的 32 位十六进制**必然**得到 `400 invalid_uid`（不满足 26 位形态）；即便将来派生出形态合法的 id，未在服务端登记仍是 `404 unknown_uid`。批量同步时需按此码停止本轮、不要无脑重试。
- **后续改造**：数据源接入与 M10 Reader 将改为「路径 → `GET /api/resolve?root=&path=` → uid」，把 `(root, path) → uid` 的映射缓存在 `seshat_app_prefs`（普通偏好，不加密、可重建），仅缓存服务端返回的 uid，不在客户端生成。
- **无需迁移**：服务端与客户端均尚未部署，本地旧 `documentId` 名下的进度/批注可直接**清空**（删除对应 prefs 键即可），不需要做 id 迁移或双写过渡期。
- 契约细节见 [`docs/api.md`](api.md) §6（路径解析）与 [`docs/sync-protocol.md`](sync-protocol.md) §2（身份模型）。

## 10. 与 M7 服务端对接（M9.2 A 批）

第 9 节描述的「已知不一致」是本批改造前的状态（保留作背景）；M9.2 A 批已解决 Android 侧：不再把内容哈希当 uid 发送，而是由服务端解析出 uid，无 uid 时完全离线。本批**只做只读协议 + 索引 + 增量 + 阅读器 uid 接入**，文件同步（书架）留 B 批。

### 10.1 uid 的来源与解析

- uid 由**服务端生成**（26 位 Crockford Base32），客户端**不生成、不解析**，只透传。
- 路径 → uid 的唯一入口是 `GET /api/resolve?root=&path=`（`sync/RestClient.resolve`：200 返回 uid，404 → `null`，400 抛 `ApiException`）。
- uid 与路径解耦：**rename 后 uid 不变**；删除后同一路径重建会**复用原 uid**（墓碑保留 uid 与 path 的意义），因此「按路径缓存 uid」在删除重建后仍然有效。
- A 批按**单根**实现（服务端默认只有 `notes`，mode=mirror）；多根 / ondemand 根留 B 批。

### 10.2 阅读器的两条路径

| 打开方式 | Store 键 | 同步 |
|---|---|---|
| **有 uid**（书架 / 索引打开，Intent 带 `EXTRA_UID`） | uid | 启用（进度 + 批注） |
| **无 uid**（SAF 或直接打开） | 内容哈希（EPUB：SHA-256 前 16 字节，32 位十六进制）或文件 `uri.toString()`（PDF） | **纯本地**，零网络调用 |

- 键选择的唯一判定点在 Activity：`effectiveKey = uid ?: docId`，随后透传给五个 Store（`ReadingProgressStore`、epub `AnnotationStore`、`PdfProgressStore`、`PdfAnnotationStore`、`PdfInkStore`），Store 内部不做判断。
- 同步装配有三条守卫（`sync/ReaderSync.createReaderSync`）：① uid 非空；② `SettingsStore.toConfig() != null`（地址与令牌齐备）；③ 装配成功。任一不满足即静默返回，**不构造 `RestClient`**——保持「服务端未配置时零网络行为」。

### 10.3 本地资源索引

- `sync/ResourceIndex.kt`：`SharedPreferences("seshat_resource_index")` 的**单文件 JSON**（键 `index`），内容为 `ResourceIndexDocument(cursor, entries)`；条目 `ResourceEntry(uid, root, path, blob, size, mtime, deleted, dirty)`。
- **零新增依赖**（不引入 Room / SQLite）；读写函数注入，纯逻辑可 JVM 单测。
- **索引是派生状态**：可随时 `clear()` 后 `bootstrap()` 从 `/api/changes` 重建，不是唯一真相；`cursor` 与条目一起原子落盘，是唯一需要持久化的同步位置。
- 写 API：`upsertAll`（批量，消除 O(N²) 写放大）/ `rename` / `markDeleted` / `setCursor` / `clear`；查 API：`findByUid` / `findByPath` / `alive()` / `entriesInRoot`。
- 容量按「数千条资源、单文件数百 KB」设计，且**假定单线程串行调用、不加锁**。
- A 批只交付 `SyncEngine`（`bootstrap` / `pull`），**尚未接线**——当前没有任何调用方，书架 B 批接入。

### 10.4 增量游标

- `GET /api/changes?since=&limit=`（`limit` 上限 2000）：`op ∈ create/update/rename/delete`，响应含 `next_cursor`（int64）与 `has_more`。
- `sync/SyncEngine` 每页**先应用事件、再存 `next_cursor`**：两者之间崩溃则重启后重复应用同一页——`apply` 幂等，所以最多多花一次网络，**绝不丢事件**（反之先存游标会永久跳过整页）。
- `has_more == true` 而游标未前进 → 抛 `IllegalStateException`，拒绝死循环重试同一页；未知 `op` 忽略（服务端新增操作类型时旧客户端仍能同步其余事件）。
- `rename` 只用 `path`（`oldPath` 仅作日志线索，uid 才是稳定键）；`delete` 只置墓碑位，保留 uid 与 path。
- `create/update` 的 `size` / `mtime` 只能继承索引既有值（`/api/changes` **不含**这两个字段）；全新条目无从得知 → `size = 0`、`mtime = 0` 且 `dirty = true`，表示「待 `GET /api/resources` 回填」。

### 10.5 同步触发与失败语义

| 时机 | 动作 |
|---|---|
| 打开书籍（有 uid 且服务端已配置） | `pullAnnotations` 合并远端批注；**本地无进度时**才 `pullProgress`（避免覆盖本机正在读的位置）；随后 `pushProgress` |
| 新增批注 | 即时 `pushAnnotations`（按 `location + text` 去重，幂等） |
| 离开阅读器（`onStop`） | `pushProgress` 一次（每次翻页推送会让请求爆炸；同值跳过只是防抖） |

- 全部网络调用在**单线程 executor** 上串行执行；异常由 `runCatching` 吞掉并记一条 warn 日志——阅读是本地优先功能，同步失败不得阻断或弹窗打扰。
- 已知限制：拉取到的**远端进度不立即跳转 UI**（当前阅读位置已按本地进度恢复，中途跳转会让正在读的用户丢失位置），下次打开本书才生效；`onStop` 可能因进程被杀而不执行（见 `openspec/tech-debt.md`）。
- 设置页「连通性测试」探针由「带旧参数的批注端点」改为 `GET /api/roots`（无入参、只读、不写数据）——旧写法在 M7 服务端上恒失败：批注按 uid 查询且要求 uid 已登记，客户端没有可用的已登记 uid；`/api/roots` 无此约束。旧服务端（无 M7 路由）返回 404，客户端映射为 `ServerError(404)`，设置页应提示「服务端版本可能过旧」。

### 10.6 旧键清理（只删不迁移）

- 首次打开阅读器时按「**32 位十六进制**（EPUB 内容哈希）」或「**含 `:`**（PDF uri）」判定旧键并删除；用各 prefs 文件各自的一次性标记 `legacy_cleared`（`LegacyKeys.CLEARED_FLAG`）保证只跑一次，`legacy_` 前缀的键不参与清理。
- **不迁移**：服务端与客户端均未部署，旧键名下的进度/批注直接丢弃；uid 为 26 位 Base32（既非 32 位十六进制也不含 `:`），不会误删合法新键。
- 缺口：无 uid 时的离线键形态与旧键相同，清理安全性完全依赖该标记（见 `openspec/tech-debt.md`）。

