# Android 客户端结构

本文描述 Android 客户端（`android/`）的 UI 结构与模块边界；构建与验证命令见第 9 节。

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
| 笔记 | `ui/NotesFragment` | 笔记库列表 + 笔记/Agenda 分段（M10.7，见 §8）：搜索框（只搜标题与标签）、刷新/选择目录；点文件行进 `ui/NoteViewActivity` 渲染阅读（可再进 `ui/NoteEditActivity` 编辑源码） |
| 阅读 | `ui/ReaderFragment` | 书架网格（M10.6 B3 + M9.2 B 批：扫 `filesDir/books/` 并合并服务端清单、过滤/排序、点书进阅读器，见 §7 / §9）+ 底部**单一**「导入书籍」入口（M10.8：epub / pdf 由 `BookImporter.detectType` 按扩展名自动识别，mobi 提示需转换；原「选择 EPUB」与「打开示例」两个入口已删除，示例书改为空库时静默播种，见 §7） |

阅读器（`reader/EpubReaderActivity`、`reader/PdfReaderActivity`）仍是**独立全屏 Activity**，由 Fragment 内的入口启动——沉浸阅读不占内容区，且保证既有实现零改动。`gtd/GtdActivity`（三 Spinner 过滤的旧版 GTD 页）自 M10.6 B4d 起**不再有 Fragment 入口**（Notes 的 Agenda 段取代），保留为可独立启动的 Activity。

## 3. 设置页（M9.1 起，M9.2 扩展到 8 项，M10.7 加第 9 项）

`settings/SettingsActivity` 承载全部配置：

| # | 设置项 | 存储 | 生效时机 |
|---|---|---|---|
| 1 | 服务端地址 | `SecurePrefs.KEY_SERVER_URL`（加密 prefs） | 下次请求 |
| 2 | 访问令牌 | `SecurePrefs.KEY_AUTH_TOKEN`（加密、不回填明文） | 下次请求 |
| 3 | WebDAV 远程目录 | `AppPreferences` 的 `remote_dir` | 下次同步 |
| 4 | 主题（跟随系统 / 浅色 / 深色） | `app_theme` | **立即**（`SeshatApp` 里 `AppCompatDelegate.setDefaultNightMode`，Activity 自动重建） |
| 5 | 正文字号（80–200%，**仅 EPUB 生效**） | `reader_text_zoom` | 下次打开阅读器 |
| 6 | 翻页模式（横向翻页 / 竖向连续滚动） | `reader_page_mode` | 下次打开阅读器 |
| 7 | 连通性测试 | 无存储 | 按下即测（`GET /api/roots`——无入参、只读，200 即证明「地址可达 + 令牌有效」。M7 起批注端点按 uid 查询且要求 uid 已登记，客户端没有可用的已登记 uid，故不再用批注端点探测；未升级到 M7 的旧服务端没有该路由，返回 404 → `ServerError(404)`，设置页应提示「服务端版本可能过旧」，见 §12） |
| 8 | 关于 | 无存储 | 静态（版本号 + 配置状态） |
| 9 | 笔记外部目录（SAF 目录树，只读） | `notes_external_dir`（只存 URI 字符串） | 下次扫描笔记（选择/清除立即落盘，无需点保存；持久读权限由设置页 `takePersistableUriPermission` 持有，清除时先释放权限再清偏好） |

- 存储**分两层**：机密与同步配置走 `SecurePrefs`（EncryptedSharedPreferences，见 `docs/security.md` §7）；
  远程目录 / 主题 / 字号 / 翻页模式 / 笔记外部目录走 `settings/AppPreferences`（普通 `seshat_app_prefs.xml`，不加密、参与系统备份）。
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
| `gtd/` | org 解析、过滤、树构建/搜索、行区间改写、GTD 视图与 org 上传（`NotesSync`） | 由 `NotesFragment`（Agenda 段）使用；`GtdActivity` 保留可独立启动 |
| `notes/` | 笔记扫描（私有目录 + SAF）、denote 名解析、按 `NoteRef` 读文本；`notes/render/` 做 org / markdown → HTML | `render/` 子包纯 JVM，**不得**引用任何 Android 框架类（单测直接断言 HTML 字符串）；只收 `.org` / `.md`，SAF 只遍历一层 |
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
| 手写批注（M10.5，M10.8 加笔型） | `InkOverlayView` 叠在页面 `ImageView` 之上；笔迹以**归一化坐标 0..1**（相对 FIT_CENTER 显示矩形）存于 `PdfInkStore`（键 `pdf_ink_<docId>`）；坐标换算走纯函数 `InkGeometry`（含 4 个数值示例的单测）；支持撤销上一笔、清除本页。M10.8 起每笔带 `InkStyle`（钢笔 / 马克笔 / 荧光笔，见 §6.6） |
| 交互模式（M10.5，M10.8 改入口） | 「阅读 / 手写」双模式：手写时 `InkOverlayView` 拦截触摸并 `requestDisallowInterceptTouchEvent(true)`。进入/退出手写改由**双击阅读区**或顶栏「手写」按钮触发（原「手写时浮层显示上一页/下一页」随时间工具栏改版取消，翻页改用 `SeekBar` / 点页码，见 §6.6） |
| 点击翻页与横屏（M10.5，M10.8 改分区） | 三区点击改由纯函数 `TapZone` 判定（左 `[0, 0.25)` / 中 `[0.25, 0.75]` / 右 `(0.75, 1]`，见 §6.2；早期为左 30% / 中 40% / 右 30%），`onInterceptTouchEvent` 恒返回 false 不吞滑动；横屏 + 横向模式下 `renderWidth` 按可用高度 × 首页宽高比（夹紧屏宽），浮层工具栏改为贴底半透明并加系统栏 insets |

### 5.2 EPUB（`reader/EpubReaderActivity` + `ChapterScrollAdapter`）

| 项 | 实现 |
|---|---|
| 容器 | 两套并存、按模式显示其一：`ViewPager2` + `ChapterFragment`（横向）/ `RecyclerView` + `ChapterScrollAdapter`（竖向） |
| 竖向 item | 每章一个 `WebView`，高度 = 内容高度（`onPageFinished` 后 JS 取 `scrollHeight` / `window.innerHeight`，按「视口物理高 / 视口 CSS 高」换算物理像素，与 viewport meta 无关）；`isNestedScrollingEnabled=false` |
| 复用 | **禁复用**：`setItemViewCacheSize(0)` + 逐 viewType `setMaxRecycledViews(i, 0)` + `onViewRecycled` 里 `destroy()` |
| 重锚 | 测量完成 → `notifyItemChanged` 等价的高度变化 → 若该章为当前可见章，用 `scrollToPositionWithOffset(pos, -offset)` 重锚，避免阅读位置漂移 |
| 进度 | 语义不变：`ReadingProgress(chapterIndex, scrollY)`，竖向经 `ScrollProgressMath` 换算 |
| 批注 | 横向取 `ChapterFragment` 选区；竖向取当前可见章 `WebView` 的选区，共用 `decodeJsString` |

## 6. 阅读器交互（M10.6 B2 定基调，M10.8 重排）

两个阅读器（`reader/EpubReaderActivity` / `reader/PdfReaderActivity`）的浮层、tap 与导航交互共用同一套语义：**浮层是 overlay、不占布局**（阅读区永远全屏，靠 padding 让内容避开浮层，§6.3），单击阅读区中央切换浮层显隐，左右两侧为翻页热区。

### 6.1 工具栏结构（两模式对照）

| 位置 | EPUB | PDF |
|---|---|---|
| 顶部浮层 | `←` 返回 / 章节标题 / 批注 / 目录 / 设置 | `←` 返回 / 文件名 / 手写 / 批注 / 目录 / 设置 |
| 底部浮层 | 章节 `SeekBar` + **可点击**的「第 n/N 章」 | 页 `SeekBar` + **可点击**页码 |

- **进入阅读默认隐藏两块浮层（沉浸）**：打开阅读器时不显示顶栏 / 底栏，正文铺满（上下 padding 为 0）；**点屏幕中央**（§6.2 的 `TOGGLE` 区）调出，再点中央收起；**退出**阅读用系统返回键（`←` 在浮层内，浮层隐藏时不可见）。只隐藏**应用内浮层**——系统状态栏 / 导航栏仍可见（未做系统栏 immersive，见 §6.7 第 12 条）。
- 底部「第 n/N 章」/ 页码可点击 → 输入章号 / 页号直接跳转（非法输入只提示，不跳转）；`SeekBar` 拖动中不跳、松手才跳。
- 「设置」跳既有 `settings/SettingsActivity`（M10.8 未做阅读内浮层设置面板，见 §6.7）。
- **M10.8 删除的控件**：EPUB 的 `prevChapterButton` / `nextChapterButton`、PDF 的 `pdfPrevPageButton` / `pdfNextPageButton`——翻页改由 tap 分区（§6.2）与 `SeekBar` 承担。
- **一处偏离原计划的取舍**：EPUB 原底栏「批注」按钮没有删除，而是**移到顶栏**——`addAnnotationFromSelection()` 只有这一个入口，直接删会让批注能力消失。
- 两块浮层都注册 `ViewCompat.setOnApplyWindowInsetsListener` 处理系统栏（`targetSdk 35` 起 edge-to-edge 强制，不避让会被状态栏/导航栏压住）。

### 6.2 tap 三分区（U2）

分区判定抽成纯函数 `reader/TapZone.kt`：`zone(fraction, leftEdge = 0.25f, rightEdge = 0.75f): Zone{PREV, TOGGLE, NEXT}`，越界值先 `coerceIn(0, 1)` 归一化，`NaN` 兜底为 `TOGGLE`。

| 分区 | 区间 | EPUB | PDF |
|---|---|---|---|
| `PREV` | `[0, 0.25)` | `moveOneScreen(-1)`：横向 `moveBy(-1)`（上一章）/ 竖向 `scrollView.smoothScrollBy(0, -视口高)` | 横向 `movePage(-1)` / 竖向 `recycler.smoothScrollBy(0, -视口高)` |
| `TOGGLE` | `[0.25, 0.75]`（闭区间） | `scheduleToggle()`：延迟 250ms 执行，期间第二击撤销 | `toggleChrome()`：延迟 `ViewConfiguration.getDoubleTapTimeout()` |
| `NEXT` | `(0.75, 1]` | 同 `PREV` 反向 | 同 `PREV` 反向 |

- 边界点（恰好 25% / 75%）归中间区——避免「擦边」翻页；`OnItemTouchListener.onInterceptTouchEvent` 仍恒返回 `false`（不吞滚动与吸附）。
- 视口高 = `容器高度 - paddingTop - paddingBottom`（扣除浮层 padding），否则竖向翻屏会跳过多余或重复一段内容。
- **两端的单击延迟口径不同**（已知不一致，见 §6.7）：EPUB 用常量 250ms（双击是 WebView 缩放，只需压过双击窗口）；PDF 用 `ViewConfiguration.getDoubleTapTimeout()`——PDF 侧双击要切手写，250ms 会让「慢双击」先翻页。

### 6.3 浮层 padding 联动（U1）

`applyContentPadding()`（两侧各一份）：按「浮层是否 `VISIBLE` + 当前 height」计算阅读区上下 padding，**浮层隐藏即归零**——M10.6 B2 遗留的「隐藏浮层后底部留白」由此修复。

| 机制 | EPUB | PDF |
|---|---|---|
| 幂等闸 | `appliedTopPadding` / `appliedBottomPadding` / `appliedContent`（RecyclerView 身份，容器换绑才重写） | `appliedTopPadding` / `appliedBottomPadding` |
| 触发 | 布局监听**常驻**（不再一次性移除）：字体缩放、旋转、insets、浮层高度变化都会重算 | 同 |
| 附带动作 | 末尾调用 `reportVisibleChapter()` | — |

- 幂等闸的作用：值没变就不写 padding，**避免打断滚动锚点**（`setPadding` 触发的重布局会让 `RecyclerView` 重算可见项与偏移，显隐浮层时表现为跳动）。
- EPUB 必须主动 `reportVisibleChapter()`：padding 变化**不派发 `onScrolled`**，不主动重算会让持久化的章内偏移漂移——破坏 M10.6 的进度不变量。

### 6.4 目录（M10.9：树形左侧抽屉）

两个阅读器的目录都是**左侧滑出的树形抽屉**（`reader/TocDrawer.kt` + `reader/TocAdapter.kt`），取代 M10.6/M10.8 的 `AlertDialog.setSingleChoiceItems` 扁平列表。入口仍是顶栏「目录」（EPUB M10.8 从底栏移上来、PDF M10.8 新增）。

**数据来源两条链**

| 链 | 来源 | 层级 | 跳转目标 |
|---|---|---|---|
| EPUB | `EpubParser.parseNavTree(navXml, baseDir)`（EPUB3 nav）/ `parseNcxTree(ncxXml, baseDir)`（EPUB2 NCX）→ `EpubBook.tocTree` | 保留 `<ol><li>` / `<navPoint>` 嵌套 | `TocNode.href` 是**已归一化的 epub 根相对路径**，可直接与 `chapters[i].href` 精确比较 |
| PDF | `reader/PdfOutlineReader.kt` 读书签树（PdfBox，后台线程）→ `PdfOutlineItem` | 保留书签嵌套（受下方三重上限约束） | `pageIndex`（0 起页索引）；`-1` = 纯 URI 链接书签，不可跳转 |
| PDF 回退 | 无 outline 或解析失败 → `PdfOutlineReader.pageDirectory(pageCount)` 的「第 N 页」列表，转成同构 `PdfOutlineItem` | 一级 | 每行一页 |

- **`href` 的 base 是 nav/ncx 文档自身所在目录**（不是 `opfDir`）：`OEBPS/text/nav.xhtml` 里的 `ch1.xhtml` 归一化为 `OEBPS/text/ch1.xhtml`。归一化在**解析层**完成一次，行模型里**不要**再传 `opfDir` 二次归一化（会拼出 `OEBPS/OEBPS/x`）。
- 容器节点（只有子项、自身没有链接的 `<li>` / `<navPoint>`）：`title = ""`、`href = null`，行模型里 `targetIndex = -1`。
- 两条链在**行模型**处汇合：`TocRows.forEpub` / `TocRows.forPdf` 产出统一的 `TocRow`；`tocTree` 为空（nav 与 NCX 都没解析出层级）时 EPUB 回退 `TocRows.forEpubFlat`（每章一行，等价于 M10.6 的扁平列表）。
- `EpubBook.tocTree: List<TocNode> = emptyList()` 与既有扁平 `chapters` **并存**：`parseNav` / `parseNcx`（服务章节标题匹配与分页）**一行未改**，`parseNavTree` / `parseNcxTree` 是独立支路；nav 解析为空时仍回退 NCX（与既有 `parseToc` 口径一致）。
- **既有缺陷（M10.9 未修，见 tech-debt）**：`buildChapters` 的 `titleByHref` 仍以 `opfDir` 作 base 匹配 nav 的 href，而 nav href 实际相对 nav 文档目录——nav 在子目录时章节标题匹配失败、回退成文件名。两条支路对 base 的口径因此不一致。

**UI 形态**

| 元素 | 实现 |
|---|---|
| 面板 | 左侧滑出，宽 `min(320dp, 屏宽 × 0.78)`——窄屏不铺满，留一道可见的阅读区提示「点遮罩可关」 |
| 遮罩 | 半透明黑 `#99000000`，铺满内容容器（`android.R.id.content`），点击关闭；面板自身 `isClickable = true`，否则点面板空白会穿透到遮罩把抽屉关掉 |
| 动画 | `translationX`：面板从 `-panel.width` 滑入 200ms、滑出 160ms；遮罩 `alpha` 0↔1（160ms）。首次打开要等一次布局后再取宽度设起点，否则未测量时 `width = 0` 会「闪出」无动画 |
| 视图 | 全部**代码构建**（LinearLayout + RecyclerView + TextView），零新增 XML / drawable，**不引用任何 `R.id.`**；挂到 Activity 内容容器上，两个阅读器共用同一实现 |
| 列表 | `LinearLayoutManager` + `itemAnimator = null`（折叠刷新走整体 `notifyDataSetChanged`，动画只会造成闪烁） |

- **为什么不用 `DrawerLayout`**：它自带**边缘横向滑动手势**，会和横向阅读的左右翻页滑动抢事件；把边缘手势锁死又失去使用它的意义。故自实现「遮罩 + 面板 + `translationX`」，**只允许从顶栏「目录」按钮打开**（无边缘滑出手势）。
- 抽屉是**覆盖层**，**开合不触碰阅读区 padding**——与浮层不是一回事（浮层走 §6.3 的 `applyContentPadding`）。
- `isShowing` 取遮罩可见性（含滑出动画中），供「返回键 / 收起工具栏」判断。

**交互**

| 操作 | 行为 |
|---|---|
| 顶栏「目录」 | 打开抽屉；PDF 侧先在 `ioExecutor` 上读书签树、读完再弹；已打开时再点则关闭 |
| 打开时 | 自动展开当前章 / 当前页的**祖先链**（长目录若整树全展开会把当前项挤出屏幕）、`scrollToPosition` 滚到该项并高亮 |
| 点箭头 `▸/▾` | 折叠 / 展开（仅 `hasChildren` 的行有箭头） |
| 点标题 | `targetIndex >= 0` → 关闭抽屉并跳转；`targetIndex = -1` 的纯容器行 → **只切换折叠**（不跳第一页） |
| 返回键 | **优先关闭抽屉**（抽屉开着时消费返回，不退出阅读器） |
| 收起工具栏 | 一并收起抽屉，避免「没有工具栏却浮着目录」的悬空态 |
| 头部「×」/ 点遮罩 | 关闭抽屉 |

**层级与折叠（纯函数，JVM 可测）**

- `TocRow(title, targetIndex, depth, hasChildren, expanded, id)`；渲染缩进 = `depth × 16dp`。
- `TocRows`（树 → 完整 DFS 前序行、保留 depth，**不做折叠**）与 `TocFlatten.visibleRows(rows, expanded)`（按展开集合算可见行，用「可见深度上限」单遍扫描、不重建树）各管一件事，便于分别单测。
- `id` 用 **DFS 兄弟序号路径**（根层 `"0"`、`"1"`…，子层 `"0/2"`、`"0/2/1"`），**不用裸 href**，两个原因：① 容器节点 `href` 为 `null`，全都会撞车；② 同一文件的不同锚点（`ch1.xhtml#a` / `#b`）去掉 fragment 后同样撞车。兄弟序号路径对含容器在内的每个节点天然唯一，且**祖先 id 就是它的各级前缀**——「展开祖先链」因此是纯字符串操作。
- href 命中不到章节（锚点、跨文件目录、容器节点）时 `targetIndex = -1`：**不可跳转好过跳到错章节**。
- PDF 侧行模型复用同一套 `TocRow` / `TocFlatten`（`pageIndex` 直接作 `targetIndex`），故折叠与定位逻辑两端共用。
- 单页文本提取另有 `reader/PdfTextExtractor.kt`（长按菜单「复制本页文字」用，见 §6.6），与目录无关。

**已知限制**

1. 父节点 href 映射不到 spine 时**不可跳转**（只可折叠）——这是**正确行为而非缺陷**：容器节点没有落点，硬跳只会跳错位置。
2. 旋转屏会重建 Activity，抽屉的展开状态与滚动位置丢失（`expanded` 只在 `TocDrawer` 内存里），需重新点「目录」。
3. `tocTree` 让书架扫描时每本书多一次 nav/NCX DOM 遍历（开销小；书架变慢时可改惰性解析，见 tech-debt）。
4. `reader/PdfTocEntries.kt` 与 `reader/TocItemText.kt` 在改为抽屉后**已无生产代码引用**（两个测试类仍在跑），属待清理死代码。

**安全上限**（`PdfOutlineReader`，针对不可信 PDF 输入）：

| 上限 | 值 | 防的是什么 |
|---|---|---|
| `MAX_OUTLINE_BYTES` | 50 MiB | 文件大小闸门（超大 PDF 直接跳过解析，不 OOM） |
| `MAX_DEPTH` | 64 | 书签树递归深度（防栈溢出） |
| `MAX_NODES` | 5000 | 节点总数预算（防海量兄弟书签撑爆内存） |

- `BoundedInputStream`：**不信任** `ContentResolver.openAssetFileDescriptor().length`——外部 provider 自报值可以谎报（`0` / `-1` / 远小于实际），包一层限流把 50 MiB 从「provider 说了算」变回「App 说了算」。
- 加密 / 损坏 / 超大 / 越界一律返回**空表或空串**，不抛异常：目录解析或文本提取失败不得让阅读器崩。

### 6.5 封面三级回退（U6）

`EpubParser.pickCoverHref(manifest, epub2CoverId)` 按顺序回退：

| 优先级 | 判据 | 说明 |
|---|---|---|
| 1 | EPUB3 `properties="cover-image"` | 规范写法，最可靠 |
| 2 | EPUB2 `<meta name="cover" content="id">` → manifest 按 `id` 取 href | 存量旧书的主路径（M10.6 B3 未支持） |
| 3 | manifest 中第一个 `media-type` 以 `image/` 开头的 item | **启发式**：首图若是出版社 logo 会显示错图（§6.7） |

- 无封面（或解码失败）时书架卡片叠加 `coverInitial`：`CoverKeys.initialOf(title)` 取书名首字（大写，空书名 `?`），解码成功后才隐藏。
- PDF 封面仍为渲染首页 + `inSampleSize` 降采样后落盘（§7）。

### 6.6 手写（U7 / U8）

- **笔型**：`InkStyle { PEN, MARKER, HIGHLIGHTER }`（`@Serializable`）；`InkStroke` 新增 `style` 字段且默认 `PEN`，旧 JSON 无需迁移；`PdfInkStore.defaultJson()` 加 `coerceInputValues = true`（未知笔型回退默认值，不因脏数据整份丢弃）。
- **渲染**（`InkOverlayView`）：线宽倍率 1× / 2.2× / 3.5×，不透明度 255 / 170 / 90。**设定顺序有要求**：`Paint.setColor` 之后必须再设 `setAlpha`，否则颜色自带 alpha 会覆盖笔型的不透明度。
- **手写面板**（`activity_pdf_reader.xml` 的 `inkPanel`，仅手写模式显示）：参数面板是**屏幕右侧竖排浮动条**，宽 **96dp**、`layout_gravity="end|center_vertical"`（`R.id.content` 上覆一层，独立于顶部浮层），含 `✕`（退出手写）/ 撤销 / 清空 与 6 色 × 3 档粗细（归一化 0.0025 / 0.004 / 0.007）× 3 种笔型；选中态用 alpha 1.0 / 0.35 区分。**面板不属于顶部浮层**，故不计入 `ReaderChrome` / `applyContentPadding` 的浮层高度——不影响顶部栏高度，也不改变阅读区 padding。`c4a76d3` 之前该面板横排在顶栏内（分「颜色行 / 粗细行 / 笔型行」三行以避开 360dp 屏横向溢出），竖排后宽度固定、条数随内容纵向增长。
- **手写条覆盖正文右缘**：96dp 在实测设备（`24091RPADC`，density 2.75）为 **264px**，手写模式下这条带内的正文不可书写（未做右侧留白），见 §6.7 第 10 条。
- **进入 / 退出**：双击阅读区，或顶栏「手写」按钮；手写模式下单击**不翻页**（落笔优先）。
- **长按菜单**：复制本页文字（`PDFTextStripper` 提取当前页，写入剪贴板前截断到 10 万字符，防 binder 事务超限）/ 高亮标注 / 进入手写。

### 6.7 已知限制

1. EPUB 侧 tap 延迟仍是 250ms 常量（PDF 已改用 `ViewConfiguration.getDoubleTapTimeout()`），两端口径不一致。
2. 手写模式下无法 tap 翻页，只能拖进度条或点页码。
3. 封面第三级回退是启发式，可能取到出版社 logo 当封面。
4. 手写笔参数不跨文档记忆，也没有「最近使用」。
5. 阅读内设置面板未做——顶栏「设置」直接跳 `SettingsActivity`（离开阅读器）。
6. PDF 的 `INITIAL_CHROME_PADDING_DP = 6` 与布局 XML 的 `paddingVertical`（2dp / 4dp）不一致（既有行为，未随 M10.8 统一）。
7. ~~EPUB 目录无层级（`TocEntry` 无 `depth`）~~ **已随 M10.9 解决**（`EpubBook.tocTree` + 树形抽屉，见 §6.4）；抽屉的展开态不跨旋转保存（M10.9 已知限制）。`SeekBar` 在章 / 页数很大时精度不足（一像素跨多项），故保留输入框兜底。
8. PDF 解析的健壮性与主线程风险见 `openspec/tech-debt.md`：`pdfbox-android` 版本停在 2023、病态 PDF 可占死 `ioExecutor`、`PdfTextExtractor` 的真实 PDF 分支纯 JVM 下被 `assumeTrue` 跳过。
9. **退出手写后的第一次单击不弹工具栏**：点 `✕` 退出手写后，第一次单击屏幕中央无反应，第二次才调出浮层。疑为模式切换瞬间触摸事件被 `InkOverlayView` 消费的时序问题，**尚未定位**（见 tech-debt）。
10. **右侧手写条覆盖正文右缘**：面板宽 96dp（实测设备 264px），手写模式下这条纵向带内的正文被遮挡且不可书写；当前未做右侧留白。
11. **手写条「荧光笔」文案颜色存疑**：截图中该项文字呈灰色（其余「钢笔 / 马克笔」为白色），未确认是选中态渲染还是刷新时机导致，**未验证**（见 tech-debt）。
12. **沉浸只到应用内浮层**：进入阅读器时上下浮层隐藏，但**系统状态栏仍可见**——未做 `WindowInsetsController` 的系统栏 immersive 隐藏（阅读区靠 insets 避让，不与系统栏重叠）。

### 6.8 批注抽屉（M10.3）

两个阅读器的顶栏「批注」按钮改为打开**左侧滑出的批注抽屉**（`reader/AnnotationDrawer`），列出当前书的全部批注。

- **复用 `TocDrawer` 骨架**：遮罩 + `translationX` 面板，**不用 `DrawerLayout`**（其边缘横向手势与横向翻页抢事件），面板宽 `min(320dp, 屏宽 × 0.78)`；零新增 XML / 零 `R.id.`，视图全部代码构建。与目录抽屉**互斥**（同时只开一个，由 Activity 打开前先关另一个）。
- **按 `kind` 分组**：分组逻辑全在纯函数 `reader/AnnotationGrouping.group(items, currentPage)`，**顺序固定**「备注 → 高亮 → 手写 → 其它」，未知 `kind` 归入「其它」且每行保留原始 `kind` / `id`（仍可跳转与删除）。文案是取值契约：`[待同步]`（`dirty`）、「本页 N 处手写」/「共 N 处手写」。
- **ink 默认折叠**：`kind=ink` 在服务端是**一笔一条**，逐条渲染会淹没文本批注，故折叠成一条汇总行（`AnnotationGrouping.INK_SUMMARY_ID`，`count` = 笔数）。**文案与页号是两件事**：页号取 `inkItems.map { it.page }.distinct().singleOrNull()`（全部笔迹同页才有 `page`），文案只由「是否同页且等于当前页」决定——同页且等于当前页 → 「本页 N 处手写」；其余（跨页 / 有笔迹缺页号 / 同页但不是当前页）→ 「共 N 处手写」。**因此「共 N 处手写」也可能带 `page`、可跳转**，只有跨页或缺页号时才 `page = null`、不可跳页（跳转目标取该组第一条 ink 记录的页）。
- **跳转**：点条目行 → `RET` 语义的跳转（PDF 按 `page:<n>` 翻页；EPUB 按 `chapter:<i>@<s>-<e>` 跳章 + 章内按字符偏移滚动，见 §9 与 `LocationScroll`）；ink 汇总行按该组第一条 ink 记录的页定位。
- **编辑 / 删除**：`note` / `highlight` 行有「⋮」菜单（编辑备注 / 删除）；`ink` 汇总行**不可删除**——「⋮」隐藏、长按只提示（背后是 N 条独立记录，批量删除需服务端按 location 前缀查询，属另一轮，见 `openspec/tech-debt.md`）。
- **返回键优先关抽屉**：`OnBackPressedCallback` 中先判 `annotationDrawer.isShowing` → `hide()` 并吞掉返回，其次才是退出阅读器；打开目录/抽屉前也会先关另一块浮层。

## 7. 书架（M10.6 B3）

`ui/ReaderFragment` 由「4 个入口按钮」改为「过滤/排序条 + 封面网格 + 底部入口」；数据装配在 `reader/BookLibrary`，封面解码在 `reader/CoverCache`，过滤/排序/百分比等纯逻辑在 `reader/BookShelfLogic`（JVM 可测）。

| 项 | 实现 |
|---|---|
| 数据源 | 本地 `filesDir/books/`（`BookImporter` 的落点），只收 `.epub` / `.pdf`（扩展名忽略大小写）。**M9.2 B 批起并入服务端清单**（远端未下载的书显示为占位条目，见 §9）。扫描在后台**单线程 executor** 上执行，**首次进入较慢**——每本 EPUB 需整包 `readBytes()` + 解析 OPF，每本 PDF 需打开一次 `PdfRenderer` 取页数。损坏/加密的文件静默跳过，不影响整架 |
| 网格 | `GridLayoutManager`，列数按屏宽 dp：≥600dp → 4 列、≥400dp → 3 列、其余 → 2 列；每格为「封面 + 标题 + 作者 + 进度徽标」 |
| 进度徽标 | 百分比 = `current / totalCount`（EPUB 章节数、PDF 页数）；**0% 不显示徽标**。进度由 `ReadingProgressStore.all()` / `PdfProgressStore.loadAll()` 各取一次后按 `progressKey` 合并（遍历中反复调 Store 会重复扫 prefs） |
| 过滤 | 全部 / 未读（0%）/ 在读（1–99%）/ 已读（100%），判定在 `BookShelfLogic.matches` |
| 排序 | 最近阅读（进度 `updatedAt` 降序，无进度为 0）/ 书名 / 导入时间（`file.lastModified()` 降序），在 `BookShelfLogic.sort` |
| 封面缓存 | 内存 `LruCache<String, Bitmap>`（按 `byteCount` 计，上限 `Runtime.maxMemory() / 8`）+ 磁盘 `filesDir/covers/<key>.jpg`；同时把元数据（标题/作者/章节数/进度键）另存 `<key>.json`，下次扫描直接读缓存，**避免重复解析 EPUB 与重算内容哈希**。缓存键 = `文件名 + length + lastModified` 的 SHA-256 前 16 位 hex（`reader/CoverKeys`），文件一变即换键 |
| 封面来源 | EPUB：三级回退（EPUB3 `properties="cover-image"` → EPUB2 `<meta name="cover">` → manifest 首个 `image/*`，见 §6.5）；PDF：渲染首页并按 `inSampleSize` 降采样后落盘。无封面或解码失败时卡片显示**书名首字占位**（`CoverKeys.initialOf`，大写，空书名 `?`） |
| 打开 | EPUB → `EpubReaderActivity`；PDF → `PdfReaderActivity`。**M9.2 B 批起**：条目有 `uid` 时经 `intentForFile(..., uid)` / `intent(..., uid)` 带上 `EXTRA_UID`（进度/批注按 uid 同步，见 §9）；无 uid 时进度键为**内容哈希**（EPUB：SHA-256 前 16 字节共 32 位 hex；PDF：`file://` uri），与阅读器 `effectiveKey = uid ?: docId` 的无 uid 分支一致 |
| 示例书播种 | M10.8 起 `seedSampleIfEmptyThenRefresh()`：**书籍目录为空**时把 `assets/sample.epub` 复制进去（**不打开**），在 `scanExecutor` 上执行、完成后回主线程刷新书架。原「打开示例」入口（`openSampleEpub()`）已删除；旧版 `filesDir/sample.epub` 保留不删作回滚点，进度键是内容哈希，故播种后同一本书的进度仍可见 |

**已知限制**：

1. 进度徽标仍按 `progressKey`（内容哈希 / `file://`）取值，而阅读器在有 uid 时把进度写在 uid 键下 → 有服务端 uid 的书徽标可能恒 0（B 批未改徽标的取值逻辑；打开阅读器后的进度同步本身是通的）。
2. PDF 用书架 `file://` 与 SAF `content://` 打开是**两套进度**，互不共享。
3. ~~EPUB2 封面不支持~~ **已随 M10.8 解决**：`EpubParser.pickCoverHref` 改为三级回退（EPUB3 → EPUB2 `<meta name="cover">` → manifest 首个 `image/*`），无封面时卡片显示书名首字；第三级是启发式，可能取到出版社 logo（见 §6.5 / §6.7）。
4. `covers/` 无自动清理：书籍删除后封面与元数据缓存滞留（无容量上限）；下载换文件后旧键的 `.jpg`/`.json` 同样残留（见 §9 已知限制 6）。
5. 切 tab 不刷新书架：`show/hide` 不改变生命周期、`onResume` 不触发；从阅读器返回会刷新（`onResume` 里按需重扫 + 触发同步，见 §9）。
6. 远端未下载的书**无封面、无作者、进度恒 0**（只有文件名与大小/时间）；下载并重新扫描后才补齐。

## 8. Notes（M10.7 起：笔记库 + 渲染阅读）

笔记 tab 自 M10.7 起是**两屏结构**：`ui/NotesFragment` 是笔记库列表（一个文件一行），点行进 `ui/NoteViewActivity` 渲染阅读，阅读页菜单「编辑源码」再进 `ui/NoteEditActivity`。扫描/解析在 `notes/` 包，渲染在 `notes/render/`。

| 项 | 实现 |
|---|---|
| 数据源 | ① 私有目录 `filesDir/notes/`（默认，首启从 `assets/sample.org` 复制一份示例；**可写**）；② 设置页「笔记外部目录」选定的 SAF 目录树（`AppPreferences` 存 URI 字符串，读权限由设置页 `takePersistableUriPermission` 持久持有；**只读**）。两处**只收 `.org` / `.md`**（扩展名忽略大小写），不支持的文件静默跳过 |
| 扫描 | `notes/NoteScanner`：`scanLocal` 只用 `java.io.File`（纯 JVM 可测），`scanSaf` 走 framework `DocumentsContract` 查询子文档（**不引 `androidx.documentfile`**）。两者共用「扩展名过滤 + 标题回退链 + 按修改时间倒序」规则；目录不存在或授权失效 → 空表，不抛 |
| 标题回退链 | denote 文件名（`20240101T120000--标题__tag1_tag2.org`，`notes/DenoteName`）> 文件首个 heading > 文件名去扩展名。denote 命中时**不读文件内容**（省一次 IO，SAF 读流更贵） |
| 列表行 | 「标题（单行省略）+ 元信息（`ORG`/`MD` · `yyyy-MM-dd HH:mm`）+ denote 标签 `:a:b:`」（`item_note_file`；无标签隐藏标签，provider 不给修改时间时显示 `-`） |
| 搜索 | 只匹配**标题与标签**的包含（大小写不敏感），**不搜正文**；250ms 防抖后重建列表 |
| 渲染（org） | 标题 1–5 级（`******` 以上按 h5，剥离 TODO 关键字 / `[#A]` 优先级 / 末尾 `:tag:`）、TODO 着色、行内 `*粗*` `/斜/` `_下_` `~代码~` `=等宽=` `+删除+`、有序/无序列表（2 空格缩进一层）、`#+BEGIN_SRC` / `BEGIN_EXAMPLE` / `BEGIN_QUOTE` 块、`[[link]]`、`:PROPERTIES:` 抽屉折叠为 `<details>`、`#+TITLE:` 等关键字行隐藏、`DEADLINE:`/`SCHEDULED:`/`CLOSED:` 计划行保留可见 |
| 渲染（markdown） | ATX 1–6 级（闭合 `##` 剥掉、词内 `C#` 保留）、`**粗**` `*斜*` `` `代码` `` `~~删除~~`、列表、围栏代码块（内容只转义不解析；未闭合的围栏把余下内容全当代码）、`[t](u)`、`>` 引用、`---` / `***` / `___` 水平线 |
| 安全顺序 | `notes/render/RenderSupport`：**先转义**（`& < > " '`）→ 抽出代码占位 → 抽出链接占位（URL 含 `/`，必须早于斜体规则）→ 替换强调 → 还原占位；占位符用 `\u0001` 控制字符，不会被强调正则命中。链接只允许 `http` / `https` / `mailto`，**其它 scheme 降级为纯文本**（不生成 `<a>`） |
| 外壳与样式 | `notes/render/HtmlDocument` 只拼接固定 DOCTYPE / head / 内联 CSS（除 body 片段外不含任何源自笔记的字符）；`prefers-color-scheme` 提供亮/暗两套配色，代码块横向滚动不换行 |
| 阅读页安全 | `NoteViewActivity` 的 `WebView`：`javaScriptEnabled=false`、`allowFileAccess=false`、`allowContentAccess=false`、`domStorageEnabled=false`，不注册 `addJavascriptInterface`；`loadDataWithBaseURL(null, …)` 载入；缩放可用（内置缩放控件隐藏） |
| 编辑 | 阅读页菜单「编辑源码」→ `NoteEditActivity`：整份源码纯文本编辑、后台读写、**保留原行尾风格**（原文 CRLF 且改后只剩 `\n` 时写回前恢复 CRLF）；保存成功 `setResult(RESULT_OK)` 后阅读页重渲染，失败只 Toast 不退出（不丢输入）。**仅本地文件**（`NoteRef.LocalFile`）显示该菜单，SAF 文档只读 |
| Agenda 分段 | 汇总**所有来源** org 文件的条目（`OrgParser` → `GtdSorter.byEarliestDate` 按最早日期升序），沿用 `NotesListAdapter`；笔记/Agenda 切换时才真正换 adapter。**只读**：跨文件写回需要「条目 → 文件」反查表，本版不做，点击只给提示（切 TODO 请在笔记内编辑或用 `gtd/GtdActivity`） |
| 刷新 | 切分段、点「刷新」、从设置页/阅读页返回（`onResume`）都重新全量扫描；「选择目录」按钮跳设置页。扫描在后台单线程 executor 上执行，视图销毁时 `shutdownNow` |

**已知限制**：

1. 渲染只覆盖语法子集：**表格按普通文本**、图片不内联、无大纲；`#+BEGIN_SRC` 缺 `#+END_SRC` 会把余下全文吞进代码块。
2. denote 未命中时要读文件首个 heading，**逐文件 IO**（未限读前 N KB，大文件全量读）。
3. 大目录首次扫描慢：私有 + SAF 全量、**无缓存/无增量**，`onResume` 每次重扫；Agenda 段只解析前 50 个 org 文件。
4. 正文不可搜：搜索只匹配标题与标签。
5. SAF 授权失效**静默降级**为「没有外部笔记」，无用户提示（见 `openspec/tech-debt.md`）。
6. SAF 只遍历所选目录**第一层**，不递归子目录；需要多层时再次添加目录。
7. 无 `DiffUtil`：增删/搜索/分段切换都是 `notifyDataSetChanged` 整表重绑；阅读页 `baseUrl=null` 使相对链接与图片失效。

## 9. 与服务端同步（M9.2 B 批）

A 批交付但**无调用方**的 `sync/ResourceIndex` 与 `sync/SyncEngine` 在 B 批接线；书架不再只列本地文件，而是「本地 `filesDir/books/` + 服务端清单」的并集，未下载的书点一下即下载并打开。**服务端未配置时全链跳过，零网络调用**（沿用 M10.6「服务端可选」不变量）。

| 项 | 实现 |
|---|---|
| 数据源 | 本地书架仍扫 `filesDir/books/`（规则同 §7）；服务端清单由 `GET /api/resources` 经 `sync/SyncCoordinator` 写入 `ResourceIndex`，再由 `reader/RemoteBookSource` 投影成 `RemoteBook`。书架取两者并集：本地有同名文件且长度匹配即视为**已下载**，否则作为**未下载**占位条目进架（标题 = 文件名去扩展名、`totalCount = 0`、`percent = 0`、`isDownloaded = false`）。墓碑条目不进书架 |
| 装配与单实例 | `sync/SyncHolder` 是**进程级单实例**：`index()` / `coordinator()` / `restClient()` 共享同一份 `ResourceIndex`、`SyncCoordinator` 与单线程 executor（同步、回填、书架扫描全走它）。`ResourceIndex` 的锁是**实例锁**，多实例保护不了同一个 prefs 键，故必须唯一；服务端配置变更后调 `invalidate()` 清缓存 |
| 同步触发 | 首次进入书架（bootstrap）→ `syncNow(force = true)`：索引 `cursor == 0` 走 `bootstrap()` 全量，否则 `pull()` 增量；`onResume` → `syncNow(force = false)` 且 **30 s 限流**（`SYNC_MIN_INTERVAL_MS`，切回书架不每次都打网络）；刷新按钮 → 强制同步；**同步成功 / 下载完成 / 导入完成**后重新加载书架。未配置服务端 → `SyncOutcome.NotConfigured`，**零网络** |
| 元数据回填 | `/api/changes` **不含** `size`/`mtime`，create/update 产生的新条目只能写 `size = 0`、`mtime = 0` 并置 `dirty = true`；`sync/MetadataBackfill` 随后按 `GET /api/resources?root=&since=&limit=` 分页回填并清脏。`since` 是 **mtime 秒**且响应体无游标：首页 `since = null`，后续页取本页 `max(mtime)`，若该页没有带来时间前进（同秒边界）则 `since += 1` 继续；硬上限 `maxPages = 50`。**尽力而为 + 幂等**——本次漏掉的 `dirty` 条目下次 `syncNow()` 自然重试，不为此抛错；服务端已墓碑的条目转为 `markDeleted` 而非回填 |
| 按需下载 | 点击「未下载」条目 → `reader/BookDownloader.ensureLocal` → `GET /api/files?root=`（整份下载，**未用** `Range`）→ `RestClient.downloadFile` 先写 `<name>.part`，`close()` 之后才 `renameTo(<name>)`，异常路径删 `.part` → 回主线程**自动打开阅读器**。落点 `booksDir/<name>`，与 `RemoteBookSource.localFileOf` 的长度匹配判定同源；`.part` 扩展名不匹配书籍扫描，不会被打成半成品。同一本书下载中重复点击被忽略（`downloading` 集合去重） |
| 上传 | 本地导入成功后若文件 **≤ 32 MiB**（`RestClient.MAX_UPLOAD_BYTES`）→ 后台上传（`PUT /api/files`，`If-None-Match: *` 新建）→ 回填 `ResourceIndex` 并刷新书架。**超限只提示不上传**（本地文件保留）；上传失败同样只提示，不回滚本地文件 |
| 进度闭环 | 书架条目带 `uid`（`BookItem.uid`：远端条目直接来自 `RemoteBook.uid`，本地文件在与远端清单**按文件名对齐**后合并得到；未对齐则为 null），打开阅读器时经 `intentForFile(..., uid)` / `intent(..., uid)` 传入 → 阅读器按 uid 同步进度与批注（见 §12.2）。纯本地无 uid 的书仍走内容哈希 / `file://` 的纯本地路径 |
| `move` 跟随 | 服务端 rename 事件 → `SyncEngine` 收集成 `SyncResult.renames`（`RenameEvent(uid, oldPath, newPath)`）→ `SyncCoordinator.followRenames` 把 `booksDir/<oldName>` 重命名为 `booksDir/<newName>`。**仅当目标不存在时才移动**（同名不同目录的会跳过，不覆盖不删除）；**仅 mirror 根可移动**——`ondemand` 根只读，不会有 rename 事件 |
| 服务端前置 | `config.yaml` 的 `webdav.roots` 必须**显式声明** `ebooks`（`mode: ondemand`）根，客户端才能在书架上看到远端书；未配时 `RemoteBookSource` 只返回 mirror 根内的条目，功能优雅降级（不报错）。改配置需重启服务端，客户端无需额外设置（`/api/roots` 自动发现） |
| 批注闭环（M10.3） | 阅读器打开带 uid 的书时，`createReaderSync` 装配 `SyncManager`（`pendingDeletes` 一并注入）后在该书的单线程 executor 上串行执行：`pullAnnotations` → （PDF）`backfillInkAnnotations` → `pullProgress`（仅本地无进度时）→ `pushProgressDetailed` → 补登有新条目时 `pushAnnotations`。批注合并按 `(kind, location, text)` 三路匹配（服务端 `id` → 内容键 → 新增），**同 location 不同 kind 不互相去重** |
| 手写同步（M10.3 T6） | `PdfInkStore` 仍是笔迹的**渲染唯一真相**；同步的是 `kind=ink` 的**镜像批注**——落笔完成即以 `InkAnnotationMapper.inkLocation` 生成 `page:<n>;ink:<color>,<widthPt>,...`（页号 `pageIndex + 1`、坐标与线宽按页面 pt 换算、颜色 `#AARRGGBB`）并**一笔一条**登记待上传；打开带 uid 的书时把本地既有笔迹**一次性补登**，客户端先按 `(kind, location, text)` 跳过已有项，服务端 `(uid, kind, location, text)` 幂等命中返回 `200` 是第二道兜底（本地被清空后重复打开不会产生重复批注）。空点集不登记（不值得上传）。镜像不参与绘制 |
| 离线 dirty 与待删队列（M10.3 T3） | `dirty` 只表示「新增/修改待上行」，删除**不复用**该标记：删掉已上传批注时把它的服务端 `serverId` 入 `PendingDeletes`（键 `pending_deletes_<uid>`，JSON 长整型数组，与按 docId 的批注数据键隔离），从未上传的记录（`serverId == null`）删除**不发请求、不入队**。flush = `SyncManager.pushDeletes`：逐条 `DELETE /api/annotations/{id}`、**404 视为成功**并出队，同时清掉残留的本地同 `serverId` 记录。**时机**：① 阅读器 `onStop`（与进度推送同一时点）；② 每次本地删除动作之后立即异步 flush 一次。顺序不变量：待删队列必须在拉取之前或之外处理，否则服务端会把它写回本地 |
| 冲突合并（M10.3） | 批注 `PUT` 返回 409 → `UpdateAnnotationResult.Conflict` → `resolveConflict` 重拉服务端版本**以服务端为准**覆盖本地并清 `dirty`，本地被覆盖的快照作为冲突计数返回给调用方（不静默丢弃）；服务端记录已被别端删除时本地记录一并移除。删除端点 `DELETE` 的 404 在 `RestClient` 内直接当作成功 |
| 进度冲突合并（M10.3/M10.4） | `pushProgressDetailed` 返回可判别结果：`Pushed`（服务端已存本地值，含 409 后带新时间戳重发成功）/ `Merged`（409 后判定服务端较新，已用服务端值覆盖本地）/ `Rejected`（重发仍 409，本地值**未上行**）/ `Skipped`（uid 空白或本地无进度，零请求）。重发时间戳取 `max(本地, 服务端 updated_at + 1s)`（服务端秒精度）。`pushProgress` 保留为兼容包装（`Pushed`/`Merged` → `Progress`，其余 `null`），`SyncSummary.progressRejected` 记录该结局。阅读器的两个推送点（打开时的首推、`onStop`）都按三态分支：`Pushed`/`Merged` 视为成功并记防抖位置，`Rejected` 记 warn 日志 + **一次** Toast「进度同步冲突，已保留服务端版本」（每 Activity 生命周期至多一次，`progressConflictNotified`） |

**已知限制**（详见 `openspec/tech-debt.md`）：

1. **> 32 MiB 不支持上传**：服务端 `PUT /api/files` 单次请求体上限，需分片或改走 WebDAV。
2. **无后台定时同步**：只在书架前台可见时触发，关闭 App 后不拉取（不引 WorkManager）。
3. **下载无断点续传、无进度回调**：整份 `GET`，失败即从头重来，界面只有「下载中…」没有百分比。
4. **`ResourceEntry` 无 `rev`**：无法 `If-Match` 条件更新，上传是无条件覆盖。
5. **书架不区分内部/外部来源**：远端条目与本地条目同形，只有「未下载」徽标可辨。
6. **封面旧键残留**：下载后文件 `length` / `lastModified` 变化 → `CoverKeys` 换键，旧 `<key>.jpg` / `<key>.json` 不清理。
- 书架卡片标题取自 EPUB 的 OPF `<dc:title>`（PDF 用文件名）；同一 OPF 标题的多本书在书架上会显示为同名卡片，仅封面/进度可区分

## 10. 构建与验证

```sh
cd android
./gradlew :app:assembleDebug        # L1：编译与打包
./gradlew :app:testDebugUnitTest    # L2：JVM 单测（无 androidTest）
```

L3（设备安装与交互验证）需要真机或 AVD；当前环境无可用设备与系统镜像，相关缺口见 `openspec/tech-debt.md`「Android L3 设备验证缺口」。

## 11. 文档标识演进（M7 之后）

M7 把服务端的文档身份从「客户端自定字符串」改成「服务端权威 uid」，Android 侧尚未跟进，形成了明确的**已知不一致**：

- **现状**：`reader/EpubParser.documentIdOf` 用 **epub 字节内容的 SHA-256 前 16 字节**（32 位十六进制）作文档 id；PDF 侧则直接用文件 `uri.toString()` 作 docId。本地进度与批注以它为键（`PdfInkStore` 的 `pdf_ink_<docId>`、`PdfAnnotationStore` 的 `pdf_annotations_*` 等）。
- **服务端期望**：uid 是 26 位 Crockford Base32（`crypto/rand` 生成，客户端不得自行生成），两者形态与来源都不同——**内容哈希 / 本地 URI ≠ 服务端 uid**。
- **当前后果**：M7 起状态 API（`/api/progress/{uid}`、`/api/annotations?uid=`、`POST /api/annotations`）只接受 uid。Android 现版本若把 `documentId` 当 uid 发送，epub 的 32 位十六进制**必然**得到 `400 invalid_uid`（不满足 26 位形态）；即便将来派生出形态合法的 id，未在服务端登记仍是 `404 unknown_uid`。批量同步时需按此码停止本轮、不要无脑重试。
- **后续改造**：数据源接入与 M10 Reader 将改为「路径 → `GET /api/resolve?root=&path=` → uid」，把 `(root, path) → uid` 的映射缓存在 `seshat_app_prefs`（普通偏好，不加密、可重建），仅缓存服务端返回的 uid，不在客户端生成。
- **无需迁移**：服务端与客户端均尚未部署，本地旧 `documentId` 名下的进度/批注可直接**清空**（删除对应 prefs 键即可），不需要做 id 迁移或双写过渡期。
- 契约细节见 [`docs/api.md`](api.md) §6（路径解析）与 [`docs/sync-protocol.md`](sync-protocol.md) §2（身份模型）。

## 12. 与 M7 服务端对接（M9.2 A 批）

第 11 节描述的「已知不一致」是本批改造前的状态（保留作背景）；M9.2 A 批已解决 Android 侧：不再把内容哈希当 uid 发送，而是由服务端解析出 uid，无 uid 时完全离线。A 批**只做只读协议 + 索引 + 增量 + 阅读器 uid 接入**，文件同步（书架）已在 B 批完成（见 §9）。

### 12.1 uid 的来源与解析

- uid 由**服务端生成**（26 位 Crockford Base32），客户端**不生成、不解析**，只透传。
- 路径 → uid 的唯一入口是 `GET /api/resolve?root=&path=`（`sync/RestClient.resolve`：200 返回 uid，404 → `null`，400 抛 `ApiException`）。
- uid 与路径解耦：**rename 后 uid 不变**；删除后同一路径重建会**复用原 uid**（墓碑保留 uid 与 path 的意义），因此「按路径缓存 uid」在删除重建后仍然有效。
- A 批按**单根**实现（服务端默认只有 `notes`，mode=mirror）；B 批的 `SyncCoordinator` 改为遍历 `/api/roots` 的所有根（回填逐根执行），`ondemand` 根只读、不支持 `move`。

### 12.2 阅读器的两条路径

| 打开方式 | Store 键 | 同步 |
|---|---|---|
| **有 uid**（书架 / 索引打开，Intent 带 `EXTRA_UID`） | uid | 启用（进度 + 批注） |
| **无 uid**（SAF 或直接打开） | 内容哈希（EPUB：SHA-256 前 16 字节，32 位十六进制）或文件 `uri.toString()`（PDF） | **纯本地**，零网络调用 |

- 键选择的唯一判定点在 Activity：`effectiveKey = uid ?: docId`，随后透传给五个 Store（`ReadingProgressStore`、epub `AnnotationStore`、`PdfProgressStore`、`PdfAnnotationStore`、`PdfInkStore`），Store 内部不做判断。
- 同步装配有三条守卫（`sync/ReaderSync.createReaderSync`）：① uid 非空；② `SettingsStore.toConfig() != null`（地址与令牌齐备）；③ 装配成功。任一不满足即静默返回，**不构造 `RestClient`**——保持「服务端未配置时零网络行为」。

### 12.3 本地资源索引

- `sync/ResourceIndex.kt`：`SharedPreferences("seshat_resource_index")` 的**单文件 JSON**（键 `index`），内容为 `ResourceIndexDocument(cursor, entries)`；条目 `ResourceEntry(uid, root, path, blob, size, mtime, deleted, dirty)`。
- **零新增依赖**（不引入 Room / SQLite）；读写函数注入，纯逻辑可 JVM 单测。
- **索引是派生状态**：可随时 `clear()` 后 `bootstrap()` 从 `/api/changes` 重建，不是唯一真相；`cursor` 与条目一起原子落盘，是唯一需要持久化的同步位置。
- 写 API：`upsertAll`（批量，消除 O(N²) 写放大）/ `rename` / `markDeleted` / `setCursor` / `clear`；查 API：`findByUid` / `findByPath` / `alive()` / `entriesInRoot` / `dirtyEntries`；回填专用 `applyMetadata`（批量写 `blob`/`size`/`mtime` 并清 `dirty`）。
- **B 批起线程安全**：所有 public 方法加 `@Synchronized`，`all()` / `alive()` / `entriesInRoot()` / `dirtyEntries()` **返回副本**（调用方可在锁外安全遍历）。锁是**实例锁**，因此必须全进程单实例（`sync/SyncHolder`，见 §9），且仍**假定单进程**——`SharedPreferences` 跨进程不安全。
- 容量按「数千条资源、单文件数百 KB」设计；单文件**全量重写**（写放大随条目数线性增长，见 `openspec/tech-debt.md`）。
- `SyncEngine`（`bootstrap` / `pull`）由 `SyncCoordinator` 在书架侧接线，B 批起有真实调用方。

### 12.4 增量游标

- `GET /api/changes?since=&limit=`（`limit` 上限 2000）：`op ∈ create/update/rename/delete`，响应含 `next_cursor`（int64）与 `has_more`。
- `sync/SyncEngine` 每页**先应用事件、再存 `next_cursor`**：两者之间崩溃则重启后重复应用同一页——`apply` 幂等，所以最多多花一次网络，**绝不丢事件**（反之先存游标会永久跳过整页）。
- `has_more == true` 而游标未前进 → 抛 `IllegalStateException`，拒绝死循环重试同一页；未知 `op` 忽略（服务端新增操作类型时旧客户端仍能同步其余事件）。
- `rename` 只用 `path`（`oldPath` 仅作日志线索，uid 才是稳定键）；`delete` 只置墓碑位，保留 uid 与 path。
- `create/update` 的 `size` / `mtime` 只能继承索引既有值（`/api/changes` **不含**这两个字段）；全新条目无从得知 → `size = 0`、`mtime = 0` 且 `dirty = true`，表示「待 `GET /api/resources` 回填」。

### 12.5 同步触发与失败语义

| 时机 | 动作 |
|---|---|
| 打开书籍（有 uid 且服务端已配置） | `pullAnnotations` 合并远端批注；**本地无进度时**才 `pullProgress`（避免覆盖本机正在读的位置）；随后 `pushProgressDetailed`（三态处置同 §9「进度冲突合并」） |
| 新增批注 | 即时 `pushAnnotations`（按 `location + text` 去重，幂等） |
| 离开阅读器（`onStop`） | `pushProgressDetailed` 一次（每次翻页推送会让请求爆炸；同值跳过只是防抖）。`Rejected` 会弹一次「进度同步冲突，已保留服务端版本」 |

- 全部网络调用在**单线程 executor** 上串行执行；异常由 `runCatching` 吞掉并记一条 warn 日志——阅读是本地优先功能，同步失败不得阻断或弹窗打扰。**唯一例外**是进度 409 重发仍失败（`ProgressPushResult.Rejected`）：本地进度确实没上行，故记 warn + 每 Activity 生命周期一次 Toast（文案 `R.string.reader_progress_conflict`），避免两端长期分叉而无任何线索。
- 已知限制：拉取到的**远端进度不立即跳转 UI**（当前阅读位置已按本地进度恢复，中途跳转会让正在读的用户丢失位置），下次打开本书才生效；`onStop` 可能因进程被杀而不执行（见 `openspec/tech-debt.md`）。
- 设置页「连通性测试」探针由「带旧参数的批注端点」改为 `GET /api/roots`（无入参、只读、不写数据）——旧写法在 M7 服务端上恒失败：批注按 uid 查询且要求 uid 已登记，客户端没有可用的已登记 uid；`/api/roots` 无此约束。旧服务端（无 M7 路由）返回 404，客户端映射为 `ServerError(404)`，设置页应提示「服务端版本可能过旧」。

### 12.6 旧键清理（只删不迁移）

- 首次打开阅读器时按「**32 位十六进制**（EPUB 内容哈希）」或「**含 `:`**（PDF uri）」判定旧键并删除；用各 prefs 文件各自的一次性标记 `legacy_cleared`（`LegacyKeys.CLEARED_FLAG`）保证只跑一次，`legacy_` 前缀的键不参与清理。
- **不迁移**：服务端与客户端均未部署，旧键名下的进度/批注直接丢弃；uid 为 26 位 Base32（既非 32 位十六进制也不含 `:`），不会误删合法新键。
- 缺口：无 uid 时的离线键形态与旧键相同，清理安全性完全依赖该标记（见 `openspec/tech-debt.md`）。

