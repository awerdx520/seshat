# Android 客户端结构

本文描述 Android 客户端（`android/`）的 UI 结构与模块边界；构建与验证命令见第 5 节。

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
| 阅读 | `ui/ReaderFragment` | 4 个既有入口：示例 EPUB、选择 EPUB、选择 PDF、导入书籍；书架由 M10.1 接入 |

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
| 7 | 连通性测试 | 无存储 | 按下即测（`GET /api/annotations?document_id=__connectivity_probe__`——**旧写法**：M7 起服务端状态端点只认 `uid`，该探测会得到 `400`，见 §7） |
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

## 6. 构建与验证

```sh
cd android
./gradlew :app:assembleDebug        # L1：编译与打包
./gradlew :app:testDebugUnitTest    # L2：JVM 单测（无 androidTest）
```

L3（设备安装与交互验证）需要真机或 AVD；当前环境无可用设备与系统镜像，相关缺口见 `openspec/tech-debt.md`「Android L3 设备验证缺口」。

## 7. 文档标识演进（M7 之后）

M7 把服务端的文档身份从「客户端自定字符串」改成「服务端权威 uid」，Android 侧尚未跟进，形成了明确的**已知不一致**：

- **现状**：`reader/EpubParser.documentIdOf` 用 **epub 字节内容的 SHA-256 前 16 字节**（32 位十六进制）作文档 id；PDF 侧则直接用文件 `uri.toString()` 作 docId。本地进度与批注以它为键（`PdfInkStore` 的 `pdf_ink_<docId>`、`PdfAnnotationStore` 的 `pdf_annotations_*` 等）。
- **服务端期望**：uid 是 26 位 Crockford Base32（`crypto/rand` 生成，客户端不得自行生成），两者形态与来源都不同——**内容哈希 / 本地 URI ≠ 服务端 uid**。
- **当前后果**：M7 起状态 API（`/api/progress/{uid}`、`/api/annotations?uid=`、`POST /api/annotations`）只接受 uid。Android 现版本若把 `documentId` 当 uid 发送，epub 的 32 位十六进制**必然**得到 `400 invalid_uid`（不满足 26 位形态）；即便将来派生出形态合法的 id，未在服务端登记仍是 `404 unknown_uid`。批量同步时需按此码停止本轮、不要无脑重试。
- **后续改造**：数据源接入与 M10 Reader 将改为「路径 → `GET /api/resolve?root=&path=` → uid」，把 `(root, path) → uid` 的映射缓存在 `seshat_app_prefs`（普通偏好，不加密、可重建），仅缓存服务端返回的 uid，不在客户端生成。
- **无需迁移**：服务端与客户端均尚未部署，本地旧 `documentId` 名下的进度/批注可直接**清空**（删除对应 prefs 键即可），不需要做 id 迁移或双写过渡期。
- 契约细节见 [`docs/api.md`](api.md) §6（路径解析）与 [`docs/sync-protocol.md`](sync-protocol.md) §2（身份模型）。
