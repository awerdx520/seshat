package com.seshat.app.reader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.view.GestureDetector
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.activity.OnBackPressedCallback
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnNextLayout
import androidx.fragment.app.FragmentActivity
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import androidx.webkit.WebViewAssetLoader
import android.util.Log
import com.seshat.app.R
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.ReaderPageMode
import com.seshat.app.settings.SettingsActivity
import com.seshat.app.settings.SettingsStore
import com.seshat.app.sync.EpubLocalSyncStore
import com.seshat.app.sync.EpubSyncMapper
import com.seshat.app.sync.ProgressPushResult
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.RestClientSyncAdapter
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SyncManager
import com.seshat.app.sync.createReaderSync
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import kotlin.math.roundToInt

/**
 * epub 阅读界面（MVP）。
 *
 * - 章节内容：WebView 显示当前章节 HTML，资源经 https 虚拟域（[EPUB_ASSET_DOMAIN]）由内存 zip 提供；
 * - 章节导航：两种模式（[ReaderPageMode]，由设置页决定，**只在打开阅读器时生效**）：
 *   - [ReaderPageMode.HORIZONTAL]：`ViewPager2` 左右滑动，每章一页（[ChapterPagerAdapter] + [ChapterFragment]）；
 *   - [ReaderPageMode.VERTICAL]：`RecyclerView` 竖向连续滚动，章与章首尾相接（[ChapterScrollAdapter]）；
 *   两种容器同时存在于布局中，按模式只显示其一，翻页按模式分流（横向滑动 / 竖向滚动 + 点击左右边缘）。
 * - 顶部显示「第 n/N 章 · 标题」，点击标题可输入章号直接跳章；
 * - 布局为「全屏阅读区 + 顶部工具栏浮层（返回/章节标题/批注/目录/设置）+ 底部进度浮层（章节 SeekBar + 章号指示）」，单击屏幕中央切换两块浮层显隐；浮层高度按**可见性**实时写为阅读区 padding（隐藏即归零，正文铺满整屏）；
 * - 底部浮层只有章节 [SeekBar]（拖动松手才跳章）与可点的章号指示；翻页由点击屏幕左右边缘完成；
 * - 退出/翻页时持久化进度，工具栏「批注」按钮把选中文本存为批注。
 *
 * epub 打开流程（后台线程）：读取字节 → 解析（[EpubParser]）→ 计算文档 id（[documentIdOf]）→ 装配容器。
 */
class EpubReaderActivity : AppCompatActivity(), ChapterScrollHost {

    /** 当前书籍的内存 zip 源（WebView 资源处理器复用同一份，只读）。 */
    var epubSource: EpubSource? = null
        private set

    /** 文档标识（内容哈希）；**不是** Store 键（见 [effectiveKey]）。 */
    var documentId: String = ""
        private set

    /**
     * Store 键（进度/批注的唯一键选择点）：有服务端 uid 用 uid，否则退回 [documentId]。
     *
     * 书籍解析完成后才有值（[onBookReady] 中赋值）。
     */
    var effectiveKey: String = ""
        private set

    /** 服务端 uid（Intent 携带；为空表示未登记/离线打开，走内容哈希键且不参与同步）。 */
    private var uid: String? = null

    private lateinit var chapterTitleView: TextView
    private lateinit var pager: ViewPager2
    private lateinit var scrollView: RecyclerView

    /** 顶部浮层（章节标题容器）：与 [bottomChrome] 同步显隐。 */
    private lateinit var topChrome: View

    /** 底部浮层（翻页/批注按钮容器）：与 [topChrome] 同步显隐。 */
    private lateinit var bottomChrome: View

    /** 底部浮层第一行的章节进度条（0-based，`max = chapterCount() - 1`）。 */
    private lateinit var chapterSeekBar: SeekBar

    /** 底部浮层的章号指示（点击可输入章号跳章，替代原底栏的按钮行）。 */
    private lateinit var pageIndicator: TextView

    /** 目录抽屉（M10.9）：挂在 Activity 内容容器上，覆盖在阅读区之上。 */
    private lateinit var tocDrawer: TocDrawer

    /**
     * 批注抽屉（M10.3 / T5）：与 [tocDrawer] 挂在同一内容容器上，但两者互斥
     * （打开任一方前先关另一方）。
     */
    private lateinit var annotationDrawer: AnnotationDrawer

    /** 待删批注队列（M10.3 T3）：键 `pending_deletes_<uid>`，与 [annotationStore] 同一 prefs 文件。 */
    private lateinit var pendingDeletes: PendingDeletes

    private lateinit var progressStore: ReadingProgressStore
    private lateinit var annotationStore: AnnotationStore

    private var book: EpubBook? = null
    private val scrollByChapter = HashMap<Int, Int>()

    /** 竖向连续滚动的章节适配器（仅竖向模式装配）。 */
    private var scrollAdapter: ChapterScrollAdapter? = null

    /** 翻页模式与正文字号（打开阅读器时读取一次）。 */
    private var pageMode: ReaderPageMode = ReaderPageMode.HORIZONTAL
    private var textZoom: Int = AppPreferences.DEFAULT_TEXT_ZOOM

    /** 竖向模式下的当前可见章与章内偏移（进度上报的事实来源）。 */
    private var visibleChapterIndex: Int = 0
    private var visibleChapterScrollY: Int = 0

    /** 打开时的恢复起点（章节 + 章内偏移）。 */
    private var startChapterIndex: Int = 0
    private var startScrollY: Int = 0

    /** 重锚进行中标记：避免测量回调互相触发形成抖动循环。 */
    private var pendingReanchor: Boolean = false

    /** 上一次实际写入的顶部 padding（像素）；-1 表示尚未写入，见 [applyContentPadding]。 */
    private var appliedTopPadding: Int = -1

    /** 上一次实际写入的底部 padding（像素）；-1 表示尚未写入，见 [applyContentPadding]。 */
    private var appliedBottomPadding: Int = -1

    /** 上一次写入 padding 的横向内容容器（容器从 `null` 变非 `null` 时需要重写一次）。 */
    private var appliedContent: RecyclerView? = null

    /** 浮层布局监听（只挂一次，见 [applyChromePaddingOnFirstLayout]）。 */
    private var chromeLayoutListener: View.OnLayoutChangeListener? = null

    /**
     * 顶部浮层自身的垂直基础 padding（像素），与布局 XML 的 `paddingVertical` 保持一致。
     *
     * 用常量而不是读 `view.paddingTop`：insets 回调会反复执行，读当前 padding 会累加系统栏高度。
     */
    private val chromeBasePaddingPx: Int
        get() = (CHROME_BASE_PADDING_DP * resources.displayMetrics.density).roundToInt()

    /** 底部浮层自身的垂直基础 padding（像素），见 [chromeBasePaddingPx]。 */
    private val bottomChromeBasePaddingPx: Int
        get() = (BOTTOM_CHROME_BASE_PADDING_DP * resources.displayMetrics.density).roundToInt()

    /**
     * 单击 → 切换浮层的延迟投递器（缺陷 A：双击缩放的第一击 UP 也会回调 `onSingleTapUp`）。
     *
     * 用主线程 [Handler] 而非 `View.postDelayed`：不依赖任何具体 View 的生命周期，
     * 且能在 [onDestroy] 里一次清空全部挂起任务。
     */
    private val tapHandler = Handler(Looper.getMainLooper())

    /** 已排入 [tapHandler]、尚未执行的浮层切换（收到双击时撤销它）。 */
    private var pendingToggle: Runnable? = null

    /** 最近一次触摸所在容器的宽度（判定「中央区域」用，见 [tapDetector]）。 */
    private var tapViewWidth: Int = 0

    /** 手指正在拖动章节进度条（拖动期间不让滚动上报反写进度，避免与手指抢位置）。 */
    private var isTrackingSeekBar: Boolean = false

    /** 程序化写 `SeekBar.progress` 期间为 `true`：拦截由此产生的回调，防跳章回环。 */
    private var isSyncingSeekBar: Boolean = false

    /**
     * 阅读状态同步管理器。
     *
     * 仅当「有 uid」且「服务端已配置」时非 `null`（见 [setupSync]），无 uid / 未配置时始终保持
     * `null`，所有推送入口都会直接返回，从而完全跳过网络。
     */
    private var syncManager: SyncManager<ReadingProgress, BookAnnotation>? = null

    /**
     * 同步专用单线程。
     *
     * **不复用渲染/打开线程**：网络请求可能耗时数秒（服务端慢或离线超时），复用渲染线程会让绘制与
     * 章节加载一起卡住。单线程保证同一本书的拉取/推送串行执行，避免顺序错乱（如先推后拉的覆盖）。
     */
    private var syncExecutor: ExecutorService? = null

    /**
     * 上次「已成功推送」的进度标识（`"章序号:章内滚动"`，与 [EpubSyncMapper.encodePosition] 一致）。
     *
     * 只在同步线程（[syncExecutor] 的单线程）内读写：比较与更新都在同一个线程里完成，
     * 不跨线程共享，因而无需额外同步。用途见下方推送方法的说明。
     */
    private var lastPushedPosition: String? = null

    /**
     * 「进度冲突已提示过」标记（同一 Activity 生命周期内只提示一次）。
     *
     * 只在同步线程写入、只被 [notifyProgressConflict] 读取；`true` 之后不再弹提示，
     * 避免服务端持续冲突时每退出一次阅读器就打扰读者一次。
     */
    private var progressConflictNotified: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_epub_reader)

        // 目录抽屉（M10.9）：挂在内容容器最上层；点击可跳转行 → 跳章
        tocDrawer = TocDrawer(findViewById(android.R.id.content)) { index ->
            jumpToChapter(index)
        }

        // 批注抽屉（M10.3 / T5）：必须在目录抽屉之后创建，两层遮罩才不会有层级歧义
        annotationDrawer = AnnotationDrawer(
            root = findViewById(android.R.id.content),
            onItemClick = { row -> jumpToAnnotation(row) },
            onItemEdit = { row -> editAnnotationRow(row) },
            onItemDelete = { row -> deleteAnnotationRow(row) },
        )

        // 模式与字号只在打开阅读器时读取一次（设置页改动下次进来生效）。
        val prefs = AppPreferences.open(this)
        pageMode = prefs.pageMode()
        textZoom = prefs.textZoom()

        chapterTitleView = findViewById(R.id.chapterTitleView)
        pager = findViewById(R.id.chapterPager)
        scrollView = findViewById(R.id.chapterScrollView)
        topChrome = findViewById(R.id.epubTopChrome)
        bottomChrome = findViewById(R.id.epubBottomChrome)
        chapterSeekBar = findViewById(R.id.chapterSeekBar)
        pageIndicator = findViewById(R.id.pageIndicator)
        progressStore = ReadingProgressStore(this)
        annotationStore = AnnotationStore(this)
        // 待删队列与批注 store 共用同一个 prefs 文件（键空间由前缀隔离）
        pendingDeletes = PendingDeletes(this)
        uid = intent.getStringExtra(EXTRA_UID)?.trim()?.takeIf { it.isNotEmpty() }
        // 旧键一次性清理（幂等；每 prefs 文件各自标记，只跑第一次）
        clearLegacyOnce()

        // 顶部工具栏（M10.8）：返回 | 章节标题 | 批注 | 目录 | 设置
        findViewById<TextView>(R.id.backButton).setOnClickListener { finish() }
        findViewById<TextView>(R.id.tocButton).setOnClickListener { showToc() }
        findViewById<TextView>(R.id.annotateButton).setOnClickListener { addAnnotationFromSelection() }
        // 设置：复用全局设置页（阅读内浮层面板留后续里程碑）
        findViewById<TextView>(R.id.settingsButton).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        // 顶栏「列表」入口（打开批注抽屉）：代码插入，零新增 XML / 零新增 R.id.
        installAnnotationListButton()
        setupSeekBar()
        // 章号指示可点：输入章号直接跳章（章节数极大时比拖 SeekBar 更精确）
        pageIndicator.setOnClickListener { showJumpToChapterDialog() }

        // 点击手势（切换浮层显隐）：两种翻页模式的容器都挂一份监听。
        installTapPaging()
        // 系统栏 insets：浮层是 overlay，不补 padding 会被状态栏/导航栏遮挡（targetSdk 35 起
        // edge-to-edge 强制，Android 15+ 必然发生）。高度变化会让浮层变高 → 同步重算阅读区 padding。
        ViewCompat.setOnApplyWindowInsetsListener(topChrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                view.paddingLeft,
                bars.top + chromeBasePaddingPx,
                view.paddingRight,
                view.paddingBottom,
            )
            view.post { applyContentPadding() }
            insets
        }
        ViewCompat.setOnApplyWindowInsetsListener(bottomChrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                view.paddingLeft,
                view.paddingTop,
                view.paddingRight,
                bars.bottom + bottomChromeBasePaddingPx,
            )
            view.post { applyContentPadding() }
            insets
        }
        // 浮层高度 → 阅读区 padding（常驻监听：高度/可见性变化时实时跟随）
        applyChromePaddingOnFirstLayout()

        // 进入阅读即沉浸：浮层默认隐藏，阅读区铺满；点屏幕中间才调出工具栏（用户 2026-10-20 要求）
        topChrome.visibility = View.GONE
        bottomChrome.visibility = View.GONE
        // 浮层 GONE → padding 应归零；此处显式算一次并补一次 post，防止此前已按可见浮层写入过非零值
        applyContentPadding()
        topChrome.post { applyContentPadding() }

        // 横向模式才需要 pager 的回调；竖向模式下 pager 不可见，回调不会触发。
        if (pageMode == ReaderPageMode.HORIZONTAL) {
            pager.registerOnPageChangeCallback(
                object : ViewPager2.OnPageChangeCallback() {
                    override fun onPageSelected(position: Int) {
                        updateChapterTitle(position)
                        persistProgress(position)
                    }
                },
            )
        }

        chapterTitleView.text = getString(R.string.reader_loading)
        openBook()

        // 返回键：抽屉开着时先关抽屉，不退出阅读器
        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    // 三态优先级与 M10.9 目录抽屉一致（抽屉是模态层，必须先关），判定收敛在纯函数里
                    when (AnnotationGrouping.backKeyAction(anyDrawerShowing(), chromeVisible())) {
                        BackKeyAction.CloseDrawer -> {
                            if (tocDrawer.isShowing) tocDrawer.hide()
                            if (annotationDrawer.isShowing) annotationDrawer.hide()
                        }
                        // 工具栏可见时返回键先收起工具栏（与点屏幕中央同一个动作）
                        BackKeyAction.HideChrome -> toggleChrome()
                        BackKeyAction.SystemBack -> {
                            isEnabled = false
                            onBackPressedDispatcher.onBackPressed()
                        }
                    }
                }
            },
        )
    }

    override fun onPause() {
        super.onPause()
        if (book == null) return
        // 竖向模式的 scrollByChapter 已由 reportVisibleChapter 更新，这里只需触发持久化。
        if (pageMode == ReaderPageMode.VERTICAL) {
            persistProgress(visibleChapterIndex)
        } else {
            persistProgress(pager.currentItem)
        }
    }

    override fun onStop() {
        // 离开阅读器（切后台 / 退出）时推送一次进度：这是「同步」语义的唯一天然时点。
        // 必须在 super.onStop() 之前入队，保证提交时同步线程仍存活且 Activity 尚未销毁。
        enqueuePushProgress()
        // 删除传播与「新增/修改」同源时机：离线删除的批注在这里补发 DELETE（M10.3 T3）
        enqueuePushDeletes()
        super.onStop()
    }

    override fun onDestroy() {
        // 先撤销挂起的浮层切换（避免已销毁的 Activity 被 post 回调整活）
        cancelPendingToggle()
        tapHandler.removeCallbacksAndMessages(null)
        // 先停同步线程（在 super.onDestroy() 之前）。
        // 用 shutdown() 而非「立即中断」版本：后者会把队列里尚未执行的任务直接丢弃、并中断
        // 正在执行的请求；而 [onStop] 刚入队的那次进度推送是本 Activity 生命周期内
        // **唯一**一次推送（back 退出、旋转屏都会先 onStop 再 onDestroy），被丢弃就等于
        // 最后一次阅读位置永远不同步。
        // 代价：Activity 销毁后线程可能短暂存活，待已入队任务跑完即随线程池退出。
        syncExecutor?.shutdown()
        syncExecutor = null
        syncManager = null
        super.onDestroy()
        // 先解绑竖向容器：确保所有 WebView 走 onViewRecycled 销毁，避免泄漏。
        if (::scrollView.isInitialized) {
            scrollView.clearOnScrollListeners()
            scrollView.adapter = null
        }
        scrollAdapter = null
    }

    // ---- 供 ChapterFragment / ChapterScrollAdapter 使用 ----

    override fun chapterAt(index: Int): EpubChapter? = book?.chapters?.getOrNull(index)

    /** 读取章节 HTML（内存 zip，读取为本地内存操作）。 */
    override fun readChapterHtml(chapter: EpubChapter): String? {
        val bytes = epubSource?.read(chapter.href) ?: return null
        return String(bytes, Charsets.UTF_8)
    }

    fun savedScrollY(chapterIndex: Int): Int = scrollByChapter[chapterIndex] ?: 0

    fun onChapterScrolled(chapterIndex: Int, scrollY: Int) {
        scrollByChapter[chapterIndex] = scrollY
    }

    /** 章节总数（供适配器使用）。 */
    override fun chapterCount(): Int = book?.chapters?.size ?: 0

    // ---- 打开与装配 ----

    private fun openBook() {
        val path = intent.getStringExtra(EXTRA_EPUB_PATH)
        val uri = epubUriFromIntent()
        if (path.isNullOrBlank() && uri == null) {
            fail(getString(R.string.reader_no_source))
            return
        }
        Thread({
            try {
                val bytes = if (uri != null) {
                    contentResolver.openInputStream(uri)?.use { it.readBytes() }
                } else {
                    File(path!!).readBytes()
                }
                if (bytes == null || bytes.isEmpty()) throw EpubParseException(getString(R.string.reader_empty_file))
                val source = ByteArrayEpubSource(bytes)
                val parsed = EpubParser.parse(source)
                if (parsed.chapters.isEmpty()) throw EpubParseException(getString(R.string.reader_no_chapters))
                val docId = documentIdOf(bytes)
                runOnUiThread { onBookReady(source, parsed, docId) }
            } catch (t: Throwable) {
                runOnUiThread { fail(t.message ?: t.javaClass.simpleName) }
            }
        }, "epub-open").start()
    }

    private fun onBookReady(source: EpubSource, parsed: EpubBook, docId: String) {
        epubSource = source
        book = parsed
        documentId = docId
        // 键选择的唯一落点：有 uid 用 uid，否则用内容哈希
        effectiveKey = uid ?: docId
        title = parsed.title
        // 键确定之后再装配同步（setupSync 内部有三条守卫，任一不满足即完全跳过网络）。
        setupSync()

        // 横向容器始终装配（竖向模式下不可见，也无副作用）。
        pager.adapter = ChapterPagerAdapter(this, parsed.chapters.size)

        val saved = progressStore.load(effectiveKey)
        startChapterIndex = saved?.chapterIndex?.coerceIn(0, parsed.chapters.size - 1) ?: 0
        startScrollY = saved?.scrollY ?: 0
        scrollByChapter[startChapterIndex] = startScrollY

        if (pageMode == ReaderPageMode.VERTICAL) {
            pager.visibility = View.GONE
            scrollView.visibility = View.VISIBLE
            setupVerticalScroll()
        } else {
            scrollView.visibility = View.GONE
            pager.visibility = View.VISIBLE
            pager.setCurrentItem(startChapterIndex, false)
        }
        updateChapterTitle(startChapterIndex)
        // 章节总数此刻才确定：显式同步一次进度条（max = count - 1，≤1 章禁用）
        syncSeekBar(startChapterIndex)
    }

    /**
     * 装配阅读状态同步（进度 + 批注）。
     *
     * **三条守卫**（任一不满足即安静返回，不提示、不报错）：
     * 1. `uid` 非空——无 uid 时服务端 URL 里没有稳定身份，进度/批注无法归属；
     * 2. `SettingsStore.toConfig()` 非空——服务端地址与访问令牌缺一不可；
     * 3. [createReaderSync] 非空——上述两条的最终裁决点，未通过时不会构造 `RestClient`。
     *
     * **失败语义**：所有网络异常在 [syncExecutor] 线程内被 `runCatching` 吞掉并记一条 warn 日志——
     * 阅读是本地优先功能，同步失败不得阻断或弹窗打扰。
     *
     * **已知限制**：拉取到的进度只写入本地 Store，**不立即跳转 UI**（当前阅读位置已按本地进度恢复，
     * 中途跳转会让正在读的用户丢失位置）；远端进度在下次打开本书时生效。
     *
     * 线程约定：本方法只在主线程读配置，所有网络调用都在 [syncExecutor] 单线程上执行。
     */
    private fun setupSync() {
        val id = uid ?: return // 无 uid：完全跳过网络（不提示、不报错）
        val securePrefs = SecurePrefs.open(this)
        val config = SettingsStore(
            read = { key -> securePrefs.getString(key) },
            write = { key, value -> securePrefs.putString(key, value) },
            writeSecret = { key, value -> securePrefs.putSecret(key, value) },
        ).toConfig() ?: return
        val manager = createReaderSync(
            uid = id,
            config = config,
            restFactory = { RestClientSyncAdapter(RestClient(it)) },
            store = EpubLocalSyncStore(progressStore, annotationStore),
            mapper = EpubSyncMapper(),
            // 待删队列：离线删除的服务端 id 在这里持久化，flush 时补发 DELETE（M10.3 T3）
            pendingDeletes = pendingDeletes,
        ) ?: return
        syncManager = manager
        val executor = Executors.newSingleThreadExecutor().also { syncExecutor = it }
        executor.execute {
            runCatching {
                // 批注：合并（幂等，按 location + text 去重），远端新增写入本地
                manager.pullAnnotations(id)
                // 进度：仅本地没有进度时拉取（避免覆盖本机正在读的位置）
                if (progressStore.load(id) == null) manager.pullProgress(id)
                // 本地已有进度：推送上去（服务端 updated_at 会因此前进）。
                // 用 detailed 版本：409 冲突重发仍失败的结局必须单独处置，否则会落进下面这条
                // 笼统的「拉取失败（已忽略）」，冲突再次被静默吞掉（计划 T3）。
                handleProgressPush(manager.pushProgressDetailed(id), position = null)
            }.onFailure { Log.w(TAG, "拉取阅读状态失败（已忽略）", it) }
        }
    }

    /**
     * 异步推送一次进度（无同步管理器时直接返回，零网络行为）。
     *
     * **为什么不在 [persistProgress] 里推**：该方法每次翻页/滚动都会执行，若在其中推送，
     * 翻 100 页就会向 `PUT /api/progress/{uid}` 排队 100 次请求（单线程 executor 串行积压，
     * 服务端被无意义写爆）。故改为只在 [onStop] 推一次——「离开阅读器即同步」语义合理。
     *
     * **为什么比较放在 executor 内**：位置取值、与 [lastPushedPosition] 比较、推送三者都在
     * 同步线程执行——主线程零网络、也不做额外的 prefs 读；单线程内读写天然串行，
     * 不存在主线程与同步线程之间的竞态。该「同值跳过」是**防抖**（不重复推同一位置），
     * 不是严格节流（不做时间窗限流）。
     */
    private fun enqueuePushProgress() {
        val manager = syncManager ?: return
        val id = effectiveKey
        val executor = syncExecutor ?: return
        // [onDestroy] 里的 shutdown() 之后 executor 拒绝新任务（RejectedExecutionException）：
        // 正常时序下 onStop 先于 onDestroy 不会命中，但旋转屏/异常销毁等边缘时序可能让提交落在
        // shutdown 之后——兜住异常，同步失败不得影响阅读器销毁。
        runCatching {
            executor.execute {
                // 以本地已落盘的进度为准（persistProgress 已先写本地），读不到说明还没有进度。
                val position = progressStore.load(id)
                    ?.let { "${it.chapterIndex}:${it.scrollY}" } ?: return@execute
                if (position == lastPushedPosition) return@execute
                runCatching { manager.pushProgressDetailed(id) }
                    // 三态（Pushed/Merged/Rejected）逐一处置：不得再用「不抛异常即成功」判定，
                    // 否则 409 冲突被拒的结局会被当成「已推送」，两端就此长期分叉。
                    .onSuccess { result -> handleProgressPush(result, position) }
                    .onFailure { Log.w(TAG, "推送阅读进度失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
    }

    /**
     * 进度推送结果的三态处置（[SyncManager.pushProgressDetailed]）。
     *
     * | 结果 | 含义 | 处置 |
     * |---|---|---|
     * | `Pushed` | 服务端已保存本地值 | 成功，记住位置（防抖） |
     * | `Merged` | 409 后判定服务端较新，本地已被服务端值覆盖 | 成功（预期语义），不打扰读者 |
     * | `Rejected` | 409 后重发仍冲突，本地值**未上行** | warn 日志 + 一次性提示，**不得静默** |
     * | `Skipped` | 零请求（本地无进度 / uid 空白） | 什么都不做，也不记位置 |
     *
     * @param position 本次推送的位置串；仅「服务端已认可」（`Pushed` / `Merged`）时写入
     *   [lastPushedPosition]。`null` 表示调用方不在同步线程的防抖路径上（如打开书时的首推）。
     */
    private fun handleProgressPush(result: ProgressPushResult, position: String?) {
        when (result) {
            is ProgressPushResult.Pushed, is ProgressPushResult.Merged ->
                if (position != null) lastPushedPosition = position
            is ProgressPushResult.Rejected -> {
                // 服务端有记录时，其 updated_at 是判断「谁较新」的唯一线索，一并记进日志。
                Log.w(
                    TAG,
                    "进度同步冲突：409 后重发仍失败，本地进度未上行" +
                        "（服务端 updated_at=${result.remote?.updatedAt ?: "<无记录>"}）",
                )
                notifyProgressConflict()
            }
            ProgressPushResult.Skipped -> Unit
        }
    }

    /**
     * 进度冲突的一次性用户提示（同一 Activity 生命周期内最多一次）。
     *
     * 为什么必须提示：冲突意味着**本地进度没有上行**，服务端仍是旧值；读者下次在别的设备打开
     * 会回到旧位置却没有任何线索可循——计划 T3 明确禁止静默吞错。
     * 为什么去重：进度推送每次 [onStop] 都会尝试，「服务端持续冲突则每次退出都弹一次」等于骚扰；
     * 同一份「已保留服务端版本」的信息说一次足够。
     *
     * 线程：[handleProgressPush] 在 [syncExecutor] 线程调用本方法，故用 `runOnUiThread` 投递到
     * 主线程，并在投递后再判一次存活，避免 Activity 已销毁时仍操作 UI。
     */
    private fun notifyProgressConflict() {
        if (progressConflictNotified) return
        progressConflictNotified = true
        runOnUiThread {
            if (isFinishing || isDestroyed) return@runOnUiThread
            Toast.makeText(this, R.string.reader_progress_conflict, Toast.LENGTH_SHORT).show()
        }
    }

    /** 新增批注后异步推送（无同步管理器时直接返回，零网络行为）。 */
    private fun enqueuePushAnnotations() {
        val manager = syncManager ?: return
        val id = effectiveKey
        val executor = syncExecutor ?: return
        // 同 [enqueuePushProgress]：shutdown() 之后提交会被拒绝，异常一并兜住。
        runCatching {
            executor.execute {
                runCatching { manager.pushAnnotations(id) }
                    .onFailure { Log.w(TAG, "推送批注失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
    }

    /**
     * 装配竖向连续滚动容器。
     *
     * 复用策略：一级缓存与二级复用池全部关闭 —— 每章一个 [ChapterScrollAdapter.getItemViewType]，
     * 天然不会被复用池跨类型复用，但同一 viewType 仍可能进池，故逐类型把上限设为 0。
     */
    private fun setupVerticalScroll() {
        val source = epubSource ?: return
        val loader = WebViewAssetLoader.Builder()
            .setDomain(EPUB_ASSET_DOMAIN)
            .addPathHandler(EPUB_ASSET_PATH, EpubAssetHandler(source))
            .build()
        val adapter = ChapterScrollAdapter(this, loader, textZoom)
        scrollAdapter = adapter
        val layoutManager = LinearLayoutManager(this, LinearLayoutManager.VERTICAL, false)
        scrollView.layoutManager = layoutManager
        // 禁复用：一级缓存与二级池都关；viewType 每章唯一，需逐类型设上限
        scrollView.setItemViewCacheSize(0)
        // 每章一个 WebView 且离屏即销毁：任何 item 动画都会让「重建的章节」从 alpha=0 淡入，
        // 滚动/跳章时成批重建 = 持续闪烁。本项目其它列表同样关了动画。
        scrollView.itemAnimator = null
        // 章高由适配器显式给定（不是靠子项测量反推），固定尺寸可省掉一轮布局
        scrollView.setHasFixedSize(true)
        for (i in 0 until chapterCount()) scrollView.recycledViewPool.setMaxRecycledViews(i, 0)
        scrollView.adapter = adapter
        scrollView.addOnScrollListener(
            object : RecyclerView.OnScrollListener() {
                override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                    if (dy == 0) return
                    reportVisibleChapter()
                }
            },
        )
        // 恢复到上次位置（章首对齐；章内偏移用负 offset 让项顶位于视口上方）
        layoutManager.scrollToPositionWithOffset(startChapterIndex, -startScrollY)
        visibleChapterIndex = startChapterIndex
        visibleChapterScrollY = startScrollY

        // 首次进入时浮层高度可能尚未测量，applyContentPadding 会提前返回；
        // 书装配完成后强制重算一次，保证正文一开始就让出顶栏空间（真机曾出现恒 padding=0）。
        appliedTopPadding = -1
        appliedBottomPadding = -1
        appliedContent = null
        scrollView.post { applyContentPadding() }
    }

    /**
     * 由竖向滚动位置推导当前章节与章内偏移，更新标题并持久化。
     *
     * **当前章**取「覆盖视口中心的那一项」（多章同屏时 firstVisible 可能仍是上一章）；
     * **章内偏移**取中心项自身顶部已滚出视口的像素（`-centerView.top`），
     * 不得复用「首项锚点换算」（`ScrollProgressMath` 旧的 first 项路径）的 offset：
     * 那是相对 first 项的滚出量，中心项不是 first 时会错位。
     *
     * **中心点必须扣掉浮层 padding**：B2b 起 `scrollView` 带上下 padding（浮层高度），
     * 子项的 `top/bottom` 以带 padding 的 View 坐标系表达，可见区是
     * `[paddingTop, height - paddingBottom]`。直接用 `height / 2` 会比真实可见中心偏低
     * `(paddingBottom - paddingTop) / 2`（顶部约 48dp、底部含 SeekBar 更高），
     * 导致章切换提前发生，故改用 `paddingTop + (height - paddingTop - paddingBottom) / 2`。
     *
     * **章内偏移同样要扣掉 paddingTop**：`LinearLayoutManager.scrollToPositionWithOffset` 的
     * offset 以 padding 之后的可视起点为基准（`AnchorInfo.assignCoordinateFromPadding`），
     * 与恢复端对齐就必须让偏移表达「中心项顶部相对可视区顶部的滚出量」：
     * `paddingTop - top`。直接用 `-top` 会把每章开头 `paddingTop` 像素（约一块浮层高）
     * 的滚动记为 0，测量回调重锚时表现为「章加载完成后正文往上跳一小段」。
     */
    private fun reportVisibleChapter() {
        val layoutManager = scrollView.layoutManager as? LinearLayoutManager ?: return
        val first = layoutManager.findFirstVisibleItemPosition()
        val last = layoutManager.findLastVisibleItemPosition()
        if (first == RecyclerView.NO_POSITION || last == RecyclerView.NO_POSITION) return

        val bounds = (first..last).mapNotNull { position ->
            val view = layoutManager.findViewByPosition(position) ?: return@mapNotNull null
            ItemBounds(position = position, top = view.top, bottom = view.bottom)
        }
        // 可见区中心（相对 scrollView 顶部；padding 不改 height，故需人工扣除）
        val viewportCenter = scrollView.paddingTop +
            (scrollView.height - scrollView.paddingTop - scrollView.paddingBottom) / 2
        // 可视中心章；无可见项时保持原章不动
        val chapterIndex = ScrollProgressMath.visibleCenterPosition(bounds, viewportCenter)
            ?: return
        val centerView = layoutManager.findViewByPosition(chapterIndex) ?: return
        // 夹紧到「该章真实可滚动范围」：短章（内容不足一屏）只可能是 0，
        // 否则一次左右边缘翻屏（smoothScrollBy 一屏）或旧进度恢复就能把正文推出可视区 → 白屏
        val viewportHeight =
            (scrollView.height - scrollView.paddingTop - scrollView.paddingBottom).coerceAtLeast(1)
        val maxScroll = (centerView.height - viewportHeight).coerceAtLeast(0)
        val scrollY = (scrollView.paddingTop - centerView.top).coerceIn(0, maxScroll)

        if (chapterIndex == visibleChapterIndex && scrollY == visibleChapterScrollY) return
        visibleChapterIndex = chapterIndex
        visibleChapterScrollY = scrollY
        scrollByChapter[chapterIndex] = scrollY
        updateChapterTitle(chapterIndex)
        persistProgress(chapterIndex)
    }

    // ---- ChapterScrollHost 实现（竖向连续滚动） ----

    override fun onChapterMeasured(position: Int) {
        // 高度测量完成后重锚：若被测量的正是当前可见章，保持阅读位置不跳。
        if (pageMode != ReaderPageMode.VERTICAL) return
        if (position != visibleChapterIndex) return
        val layoutManager = scrollView.layoutManager as? LinearLayoutManager ?: return
        if (pendingReanchor) return
        pendingReanchor = true
        scrollView.post {
            layoutManager.scrollToPositionWithOffset(
                visibleChapterIndex,
                -visibleChapterScrollY,
            )
            pendingReanchor = false
        }
    }

    // ---- 点击手势与浮层显隐 ----

    /**
     * 点击手势检测器（单击中央区域 → 延迟切换浮层）。
     *
     * 只关心 `onSingleTapUp` / `onDoubleTap`：滑动、长按、多指都不在这里处理，交给容器自身
     * （`ViewPager2` 的翻页滑动、`RecyclerView` 的竖向滚动、WebView 的文本选择）。
     *
     * **为什么要延迟 250ms**：两个 WebView（[ChapterFragment] / [ChapterScrollAdapter]）都开了
     * `builtInZoomControls = true`，双击缩放时 `GestureDetector` 会先回调 `onSingleTapUp`
     * （双指/双击的**第一击 UP** 也是一次完整单击）再回调 `onDoubleTap`。若在 `onSingleTapUp` 里
     * 立即 `toggleChrome()`，每次双击缩放都会连带把浮层藏起来。故把切换投递到 250ms 之后
     * （约等于系统 `ViewConfiguration.getDoubleTapTimeout()` 的常用窗口），并在 `onDoubleTap`
     * 里撤销挂起的切换——只有「确实没有第二击」的单击才会真正切换。
     *
     * **三段分区（[TapZone]）**：与 PDF 侧 `PdfReaderActivity.handleTap` 共用同一套口径——
     * 左边缘即上一屏、右边缘即下一屏、中间 50% 切换工具栏。这样用户点边缘就是翻屏，
     * 不会「想翻页却把工具栏藏了」。竖向模式同样按横向坐标判定（左右翻一个可视高度）。
     * 宽度尚为 0（未布局）时不分区，一律按中央处理，避免除零后点哪都没反应。
     */
    private val tapDetector by lazy {
        GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                val width = tapViewWidth
                // 宽度未知（尚未布局）时不分区，一律按中央处理
                if (width <= 0) {
                    scheduleToggle()
                    return true
                }
                when (TapZone.zone(e.x / width)) {
                    TapZone.Zone.PREV -> moveOneScreen(-1)
                    TapZone.Zone.NEXT -> moveOneScreen(1)
                    TapZone.Zone.TOGGLE -> scheduleToggle()
                }
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                // 双击：撤销第一击挂起的切换；返回 false 让 WebView 自己做缩放
                cancelPendingToggle()
                return false
            }
        })
    }

    /** 排入一次 250ms 后的浮层切换（重复单击只保留最后一次）。 */
    private fun scheduleToggle() {
        cancelPendingToggle()
        val runnable = Runnable {
            pendingToggle = null
            toggleChrome()
        }
        pendingToggle = runnable
        tapHandler.postDelayed(runnable, TAP_TOGGLE_DELAY_MS)
    }

    /** 撤销尚未执行的浮层切换（双击/销毁时调用）。 */
    private fun cancelPendingToggle() {
        pendingToggle?.let { tapHandler.removeCallbacks(it) }
        pendingToggle = null
    }

    /**
     * 把两块浮层的实时高度写入阅读区 padding（随浮层可见性与高度实时联动）。
     *
     * **为什么要用运行时高度**：浮层高度不是固定值——标题单/双行、字号放大（`textZoom`）、
     * 按钮文案换行、系统字体缩放、`WindowInsets`（状态栏/导航栏）都会改变它。硬编码 48dp/60dp
     * 在字体放大时必然失准，仍会遮住末几行。
     *
     * **为什么监听在 [topChrome] 而不是两块都监听**：两块浮层同属一个 `FrameLayout`、同一次布局
     * 遍历中被测量，监听一块即可触发；真正读高度前用 `post` 挪到遍历结束后，保证 [bottomChrome]
     * 的 `height` 也已就绪（`onLayoutChange` 回调时序上底部浮层可能尚未测量）。
     *
     * **为什么监听常驻而不写一次就移除**：浮层高度会随字体缩放、旋转屏、`WindowInsets` 实时变化；
     * 而 [toggleChrome] 还要求 padding 随可见性联动回收（浮层是 overlay，隐藏后阅读区应铺满，
     * 否则底部/顶部留一条与浮层等高的空白）。但阅读时滚动、键盘弹出都会反复触发布局，反复写
     * padding 会打断滚动锚点（`RecyclerView` 会在 padding 变化后重新布局），故用
     * [appliedTopPadding]/[appliedBottomPadding]/[appliedContent] 做幂等闸：只在值真的变了才写。
     */
    private fun applyChromePaddingOnFirstLayout() {
        if (chromeLayoutListener != null) return
        val listener = object : View.OnLayoutChangeListener {
            override fun onLayoutChange(
                v: View,
                left: Int,
                top: Int,
                right: Int,
                bottom: Int,
                oldLeft: Int,
                oldTop: Int,
                oldRight: Int,
                oldBottom: Int,
            ) {
                // post：等本轮布局遍历结束（底部浮层高度可用）后再读
                v.post { applyContentPadding() }
            }
        }
        chromeLayoutListener = listener
        topChrome.addOnLayoutChangeListener(listener)
    }

    /**
     * 按浮层当前**可见性**与**高度**写入阅读区 padding。
     *
     * **浮层是 overlay（不占布局）**：隐藏时顶部/底部必须把 padding 归零，否则阅读区会留一条
     * 与浮层等高的空白（缺陷 U1）。
     *
     * **唯一的提前 `return`**：浮层可见但高度仍为 0（尚未测量）——此时写入 0 会让正文顶到屏幕
     * 边缘而被浮层遮挡；保留常驻监听，等下一次布局回调重试。判断用「按 `visibility` 取 0 或
     * `height`」，不用 `if (height > 0)`：`setVisibility(GONE)` 之后 `height` 仍返回上一次测量的
     * 旧值（直到下次布局），按 `visibility` 判断才能在隐藏的瞬间就归零。
     *
     * 横向模式下取不到 `ViewPager2` 内部 `RecyclerView`（见 [horizontalContent]）时 `content`
     * 为 `null`：此时只写 [scrollView]，等容器就绪后由 `appliedContent` 差异触发重写。
     *
     * 幂等闸由 [appliedTopPadding]/[appliedBottomPadding]/[appliedContent] 承担，重复调用不会
     * 反复写 padding；重试路径不打日志（避免每帧刷屏）。
     *
     * **padding 变化必须显式重锚**：`LinearLayoutManager.onLayoutChildren` 以子项的**绝对 `top`**
     * 为锚（`updateAnchorFromChildren`），`setPadding` 之后内容不会跟着 padding 移动——padding
     * 从 241 归零只是把「可滚动区域起点」上移，子项仍停在 y=241（真机实测：隐藏浮层后正文视觉
     * 不动、顶部留 241px 白）。故写入前后记录「首个可见项相对**内容起点**的偏移」并用
     * `scrollToPositionWithOffset` 放回：该偏移才是「读者正在读的位置」，padding 变化时必须守恒。
     */
    private fun applyContentPadding() {
        if (!::scrollView.isInitialized) return
        val topVisible = topChrome.visibility == View.VISIBLE
        val bottomVisible = bottomChrome.visibility == View.VISIBLE
        val topHeight = topChrome.height
        val bottomHeight = bottomChrome.height
        // 浮层可见但尚未测量（height 为 0）：等下一次布局回调再写，避免写入 0 造成正文顶到边缘
        if (topVisible && topHeight <= 0) return
        if (bottomVisible && bottomHeight <= 0) return
        val padding = ReaderChrome.padding(topVisible, bottomVisible, topHeight, bottomHeight)
        val top = padding.top
        val bottom = padding.bottom
        val content = horizontalContent()
        if (top == appliedTopPadding && bottom == appliedBottomPadding && content === appliedContent) {
            return
        }
        // 记录锚点：首个可见项相对**内容起点**（padding 起点）的偏移。
        // 这个量代表「读者正在读的位置」，padding 变化时必须保持不变——
        // 否则 LinearLayoutManager 会以子项绝对 top 为锚，内容不跟着 padding 移动，
        // 隐藏浮层后正文就停在原处、顶部留一条与顶栏等高的白（真机实测 241px）。
        val layoutManager = scrollView.layoutManager as? LinearLayoutManager
        val oldTop = scrollView.paddingTop
        val anchorPosition = layoutManager
            ?.findFirstVisibleItemPosition()
            ?.takeIf { it != RecyclerView.NO_POSITION }
        val anchorOffset = anchorPosition
            ?.let { layoutManager.findViewByPosition(it)?.top }
            ?.minus(oldTop)

        content?.let {
            it.setPadding(0, top, 0, bottom)
            // 必须开：否则正文被裁在 padding 内，而不是延伸到半透明浮层下方
            it.clipToPadding = false
        }
        scrollView.setPadding(0, top, 0, bottom)
        scrollView.clipToPadding = false
        appliedTopPadding = top
        appliedBottomPadding = bottom
        appliedContent = content

        // 显式把锚点放回同样的内容偏移：padding 变大 → 内容整体下移，变小 → 上移铺满
        if (layoutManager != null && anchorPosition != null && anchorOffset != null) {
            layoutManager.scrollToPositionWithOffset(anchorPosition, anchorOffset)
        }

        // padding 变化会重排内容，但**不派发 onScrolled**（dy == 0），章内偏移需重算一次。
        // 关键是必须等**下一轮布局完成**再算：setPadding 只是 requestLayout，此刻
        // findViewByPosition(...).top 还是旧 padding 下的几何，同步算会把「旧几何 + 新 padding」
        // 的混合值记成 scrollY，再经 onChapterMeasured 重锚，正文会被拉到错误位置
        // （真机表现为：隐藏浮层后正文反而下移一整条顶栏高度）。用 doOnNextLayout 而非 post，
        // 与 jumpToChapter 的既有写法一致。
        scrollView.doOnNextLayout { reportVisibleChapter() }
    }

    /**
     * 横向模式的真实内容容器（`ViewPager2` 内部的 `RecyclerView`）。
     *
     * `ViewPager2`（1.1.0）既未重写 `setPadding` 也未转发 `clipToPadding`：直接给它设 padding
     * 只会让内部 `RecyclerView` 变小（正文虽不被遮挡，但也不会延伸到浮层下方）。
     * 故把 padding 下到内部 `RecyclerView`；取不到时返回 `null`（此时横向模式保持原样，
     * 与 tap 监听取不到内部 `RecyclerView` 时的降级策略一致）。
     */
    private fun horizontalContent(): RecyclerView? = pager.getChildAt(0) as? RecyclerView

    /** 横向模式 tap 监听是否已挂到 ViewPager2 内部 `RecyclerView` 上（只挂一次）。 */
    private var pagerTapInstalled: Boolean = false

    /** 「取不到内部 `RecyclerView`」的 warn 日志是否已打过（只在首次失败时打，避免每次布局刷屏）。 */
    private var pagerTapWarned: Boolean = false

    /**
     * 安装 tap 手势（两种翻页模式都生效）。
     *
     * - 竖向模式：直接挂在 [scrollView]（外层 `RecyclerView`）上；
     * - 横向模式：`ViewPager2` 内部就是一个 `RecyclerView`，取 `getChildAt(0)` 挂同一个监听。
     *
     * **不消费触摸事件**：[onInterceptTouchEvent] 恒返回 `false`，仅把事件喂给
     * [tapDetector]——一旦返回 `true` 就会吞掉滑动，破坏 `ViewPager2` 的翻页与
     * `RecyclerView` 的滚动。
     *
     * 时序说明：`ViewPager2` 在构造时就已把内部 `RecyclerView` 加为子 View，通常
     * `onCreate` 里就能取到；为防不同版本/自定义封装带来的差异，取不到时再挂一个
     * **一次性** `OnLayoutChangeListener`，在首次布局后重试。
     *
     * **已知限制**：横向 tap 依赖 `ViewPager2` 内部 `RecyclerView`，若始终取不到
     * （内部实现变更/子 View 布局不同），则横向模式 tap 不可用——仅记 warn 日志，
     * 不崩溃，翻页与竖向 tap 不受影响。
     */
    private fun installTapPaging() {
        val listener = object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: MotionEvent): Boolean {
                // 记录容器宽度：onSingleTapUp 里的 e.x 是相对该容器的坐标
                tapViewWidth = rv.width
                tapDetector.onTouchEvent(e)
                return false
            }
        }
        // 竖向模式：外层 RecyclerView
        scrollView.addOnItemTouchListener(listener)
        // 横向模式：ViewPager2 内部 RecyclerView（取不到则等首次布局重试一次）
        if (!installPagerTap(listener)) {
            pager.addOnLayoutChangeListener(object : View.OnLayoutChangeListener {
                override fun onLayoutChange(
                    v: View,
                    left: Int,
                    top: Int,
                    right: Int,
                    bottom: Int,
                    oldLeft: Int,
                    oldTop: Int,
                    oldRight: Int,
                    oldBottom: Int,
                ) {
                    if (installPagerTap(listener)) pager.removeOnLayoutChangeListener(this)
                }
            })
        }
    }

    /**
     * 尝试把 tap 监听挂到 `ViewPager2` 内部 `RecyclerView` 上。
     *
     * @return 已挂载（含此前已挂过）返回 `true`；取不到内部 `RecyclerView` 返回 `false`。
     */
    private fun installPagerTap(listener: RecyclerView.OnItemTouchListener): Boolean {
        if (pagerTapInstalled) return true
        val inner = pager.getChildAt(0) as? RecyclerView
        if (inner == null) {
            // 只在首次失败时告警：该方法由每次布局回调重试，反复 Log.w 会刷屏
            if (!pagerTapWarned) {
                pagerTapWarned = true
                Log.w(TAG, "未取到 ViewPager2 内部 RecyclerView，横向模式 tap 暂不可用")
            }
            return false
        }
        inner.addOnItemTouchListener(listener)
        pagerTapInstalled = true
        return true
    }

    /**
     * 切换浮层工具栏显隐。
     *
     * **为什么顶部与底部同步显隐**：它们共同构成「工具栏」这一个整体语义——用户点中央是为了
     * 要么「专心读书」（两者都藏）、要么「操作/查看章节信息」（两者都要用，如看标题再点下一章）。
     * 分开显隐会产生「只剩标题没按钮」或「只剩按钮不知在第几章」的半残状态，因此必须同进同退。
     *
     * 显隐状态**不持久化**（与 PDF 阅读器一致）：每次进入阅读器都是默认可见。
     */
    private fun toggleChrome() {
        // 两者始终同步，故任取其一判断当前状态即可。
        val target = if (topChrome.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        topChrome.visibility = target
        bottomChrome.visibility = target
        // 关键：padding 必须随可见性联动（浮层是 overlay，隐藏后阅读区应铺满）
        applyContentPadding()
        // GONE → VISIBLE 的那一刻 height 仍是 0，applyContentPadding 会提前返回（等测量），
        // 故再投递一次，在本轮布局结束后按真实高度补写（否则显示浮层后 padding 停在 0，
        // 正文前几行被顶栏压住）。
        topChrome.post { applyContentPadding() }
        // 浮层收起时抽屉若开着也一并收起，避免「没有工具栏却浮着目录」的悬空态
        if (::tocDrawer.isInitialized && tocDrawer.isShowing) tocDrawer.hide()
        if (::annotationDrawer.isInitialized && annotationDrawer.isShowing) annotationDrawer.hide()
    }

    // ---- 导航与标题 ----

    private fun moveBy(delta: Int) {
        val count = chapterCount()
        if (count == 0) return
        val current = currentChapterIndex()
        val target = (current + delta).coerceIn(0, count - 1)
        if (target == current) return
        if (pageMode == ReaderPageMode.VERTICAL) {
            scrollView.smoothScrollToPosition(target)
        } else {
            pager.setCurrentItem(target, true)
        }
    }

    /**
     * 按当前模式翻一屏：横向翻一章（复用 [moveBy] 的边界与吸附），竖向滚动一屏。
     *
     * 滚动量取**可视高度**（容器高度减去上下浮层 padding），这样隐藏/显示工具栏后
     * 「一屏」的语义仍然是「当前能看到的正文高度」。
     */
    private fun moveOneScreen(delta: Int) {
        if (pageMode == ReaderPageMode.HORIZONTAL) {
            moveBy(delta)
            return
        }
        if (!::scrollView.isInitialized) return
        val viewport = (scrollView.height - scrollView.paddingTop - scrollView.paddingBottom)
            .coerceAtLeast(1)
        scrollView.smoothScrollBy(0, delta * viewport)
    }

    /**
     * 当前章序号（两种模式各取自己的事实来源）。
     *
     * 竖向连续滚动下 `pager` 不可见、`currentItem` 恒为恢复起点，只有 [visibleChapterIndex] 反映
     * 读者真实所在；横向翻页反之（`visibleChapterIndex` 不更新）。[moveBy] 与 [showToc] 共用这一处
     * 口径，避免两处各写一遍三元判断而走偏。
     */
    private fun currentChapterIndex(): Int =
        if (pageMode == ReaderPageMode.VERTICAL) visibleChapterIndex else pager.currentItem

    private fun updateChapterTitle(index: Int) {
        val chapters = book?.chapters ?: return
        val chapter = chapters.getOrNull(index) ?: return
        chapterTitleView.text = getString(
            R.string.reader_chapter_title,
            index + 1,
            chapters.size,
            chapter.title,
        )
        pageIndicator.text = getString(R.string.reader_page_indicator, index + 1, chapters.size)
        // 标题更新即「当前章变化」的唯一汇聚点（pager 选中 / 竖向滚动上报 / 首次装配），
        // 故进度条同步放在这里，三种模式共用一条路径。
        syncSeekBar(index)
    }

    /**
     * 装配章节进度条的监听。
     *
     * **只在松手时跳章**：拖动过程中 `onProgressChanged` 恒不动作（不预览标题、不跳转）——
     * 拖过 300 章会连续触发上百次跳转，横向模式下即上百次 `setCurrentItem`，而
     * `ViewPager2` 只认最后一次，前 99 次都是白做的布局与 Fragment 创建。
     */
    private fun setupSeekBar() {
        chapterSeekBar.max = 0
        chapterSeekBar.progress = 0
        chapterSeekBar.isEnabled = false
        chapterSeekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                // 拖动中什么都不做（保持简单）；程序化 setProgress 的 fromUser = false 也在此被忽略，
                // 是防回环的第一道闸（第二道是 isSyncingSeekBar，见 onStopTrackingTouch）。
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {
                isTrackingSeekBar = true
            }

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                isTrackingSeekBar = false
                // 防回环：程序化 setProgress 不会走到这里（它不产生 tracking），
                // 但仍用闸门兜住「同步期间被外部拖动」的极端时序。
                if (isSyncingSeekBar) return
                jumpToChapter(ChapterSeekMath.indexOf(seekBar?.progress ?: 0, chapterCount()))
            }
        })
    }

    /**
     * 把当前章同步到进度条（程序化写入，**不得**触发跳章）。
     *
     * 回环防护用布尔闸门 [isSyncingSeekBar] 而非 `SeekBar.isPressed` / `isTracking`：
     * - `setProgress` 触发的是 `onProgressChanged(fromUser = false)`，本身不进 `onStopTrackingTouch`；
     * - 但 `jumpToChapter` → 容器滚动 → `reportVisibleChapter` → `updateChapterTitle` →
     *   `syncSeekBar` 是**同一个调用栈内**的同步链，一旦将来有人在 `onProgressChanged` 里
     *   加了动作就会立刻打环。布尔闸门把这个窗口显式圈出来，代价是两个赋值。
     *
     * 拖动期间（[isTrackingSeekBar]）不覆盖用户手指的位置，避免「手指还在拖，进度被滚动上报拉回」。
     */
    private fun syncSeekBar(chapterIndex: Int) {
        if (!::chapterSeekBar.isInitialized) return
        if (isTrackingSeekBar) return
        val count = chapterCount()
        isSyncingSeekBar = true
        try {
            chapterSeekBar.max = ChapterSeekMath.maxFor(count)
            chapterSeekBar.progress = ChapterSeekMath.progressOf(chapterIndex, count)
            // 0 章 / 1 章无处可跳，禁用后视觉上也不会诱导拖动
            chapterSeekBar.isEnabled = count > 1
        } finally {
            isSyncingSeekBar = false
        }
    }

    /**
     * 跳章（绝对定位，复用两种模式各自的既有一次性定位 API）。
     *
     * - 横向：`pager.setCurrentItem(target, false)` 立即生效（无动画，与恢复进度一致）；
     * - 竖向：`scrollToPositionWithOffset(target, 0)`，章内偏移归 0（跳章语义是「到该章开头」）。
     *
     * **为什么竖向要在此处手写 [visibleChapterIndex] / [scrollByChapter]**：跳章语义就是「到该章
     * 开头」，状态必须立即定死。不能只靠 `doOnNextLayout` → [reportVisibleChapter] 回填——
     * `scrollToPositionWithOffset` 是**布局型**跳转（RecyclerView 只在真实滚动时派发 `onScrolled`），
     * 短章（内容不足一屏）的章内偏移一旦非 0，正文就会被推出可视区而表现为白屏且永不恢复。
     * 章内偏移归 0 不构成「误记为读过某偏移」：跳章后的位置本就是该章开头。
     */
    private fun jumpToChapter(index: Int) {
        val count = chapterCount()
        if (count == 0) return
        val target = index.coerceIn(0, count - 1)
        if (pageMode == ReaderPageMode.VERTICAL) {
            (scrollView.layoutManager as? LinearLayoutManager)?.scrollToPositionWithOffset(target, 0)
            // 跳章语义就是「到该章开头」：立即把状态定死。
            // 不能只靠 doOnNextLayout → reportVisibleChapter 回填——布局型跳转不派发 onScrolled，
            // 而短章（内容不足一屏）的章内偏移一旦非 0，正文就会被推出可视区表现为白屏。
            visibleChapterIndex = target
            visibleChapterScrollY = 0
            scrollByChapter[target] = 0
            updateChapterTitle(target)
            persistProgress(target)
        } else {
            pager.setCurrentItem(target, false)
        }
    }

    /**
     * 点击标题 → 输入章号跳章。
     *
     * 用 `AlertDialog` + 数字键盘 `EditText`（与批注对话框同一套写法）；输入为 **1-based**，
     * 换算与夹紧全部交给 [ChapterSeekMath.indexFromUserInput]（纯逻辑，已有单测覆盖）。
     * 非法输入（空白/非数字/≤0）只提示不跳转，弹窗保持已关闭——重开一次比在对话框里
     * 校验后再报错更简单，且输入法遮挡影响更小。
     */
    private fun showJumpToChapterDialog() {
        val count = chapterCount()
        if (count == 0) return
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = getString(R.string.reader_jump_chapter_hint, count)
        }
        val container = FrameLayout(this).apply {
            setPadding(48, 32, 48, 0)
            addView(
                input,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.reader_jump_to_chapter)
            .setView(container)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val target = ChapterSeekMath.indexFromUserInput(input.text.toString(), count)
                if (target == null) {
                    Toast.makeText(this, R.string.reader_jump_invalid, Toast.LENGTH_SHORT).show()
                } else {
                    jumpToChapter(target)
                }
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /**
     * 打开目录抽屉（M10.9）。
     *
     * 优先用保留层级的 [EpubBook.tocTree]；为空（nav / NCX 都没解析出层级）时回退扁平章节列表。
     * 抽屉自带折叠/展开与滚动定位，当前章节会被自动展开到可见。
     */
    private fun showToc() {
        val book = book ?: return
        val missing = getString(R.string.reader_chapter_untitled)
        val rows = if (book.tocTree.isEmpty()) {
            TocRows.forEpubFlat(book.chapters, missing)
        } else {
            TocRows.forEpub(book.tocTree, book.chapters, missing)
        }
        if (rows.isEmpty()) {
            Toast.makeText(this, R.string.reader_toc_empty, Toast.LENGTH_SHORT).show()
            return
        }
        val current = currentChapterIndex()
        tocDrawer.show(
            allRows = rows,
            currentTarget = current,
            statusLine = getString(R.string.reader_toc_status, current + 1, book.chapters.size),
            // EPUB 暂无书签功能：传空表，抽屉书签页显示「尚无书签」空态
            bookmarks = emptyList(),
            onBookmarkAdd = {},
            onBookmarkDelete = {},
            // EPUB 顶栏没有书签图标：空态只留标题，不渲染「点顶栏书签图标」的假指引
            bookmarksSupported = false,
        )
    }

    // ---- 批注抽屉（M10.3 / T5）----

    /** 是否有任一抽屉正在显示（返回键分派用）。 */
    private fun anyDrawerShowing(): Boolean =
        (::tocDrawer.isInitialized && tocDrawer.isShowing) ||
            (::annotationDrawer.isInitialized && annotationDrawer.isShowing)

    /** 顶栏是否可见：沉浸模式（浮层已隐藏）时返回键应退出页面，而不是「隐藏一个已隐藏的工具栏」。 */
    private fun chromeVisible(): Boolean = topChrome.visibility == View.VISIBLE

    /**
     * 顶栏「列表」入口（打开批注抽屉）。
     *
     * 顶栏已有「批注」（`annotateButton`，对选中文本新建批注），故本按钮文案取「列表」以区分。
     * 视图由代码克隆同排「目录」按钮的可视属性后插入其左侧：零新增 XML、零新增 `R.id.`，
     * 与同排按钮高度/涟漪一致，浮层显隐与 insets 联动自动生效。
     */
    private fun installAnnotationListButton() {
        val row = topChrome as? LinearLayout ?: return
        val tocButton = findViewById<TextView>(R.id.tocButton)
        val density = resources.displayMetrics.density
        val button = TextView(this).apply {
            text = ANNOTATION_DRAWER_ENTRY_LABEL
            textSize = 14f
            gravity = Gravity.CENTER
            setTextColor(0xFFFFFFFF.toInt())
            minWidth = (48 * density).toInt()
            val horizontal = (10 * density).toInt()
            val vertical = (12 * density).toInt()
            setPadding(horizontal, vertical, horizontal, vertical)
            isClickable = true
            isFocusable = true
            // 复用目录按钮的 selectableItemBackground（涟漪），不引入新 drawable
            background = tocButton.background?.constantState?.newDrawable(resources)?.mutate()
            setOnClickListener { showAnnotationList() }
        }
        val index = row.indexOfChild(tocButton)
        row.addView(button, if (index >= 0) index else row.childCount)
    }

    /** store → 中性条目；EPUB 没有「页」，故 `page` 恒为 `null`（跳转目标由 location/chapterIndex 决定）。 */
    private fun annotationItems(): List<AnnotationItem> =
        annotationStore.list(effectiveKey).map { annotation ->
            AnnotationItem(
                id = "epub:${annotation.id}",
                kind = annotation.kind,
                note = annotation.note,
                selectedText = annotation.selectedText,
                page = null,
                pending = annotation.dirty,
            )
        }

    /**
     * 打开批注抽屉（已开则关闭，与目录按钮的 toggle 语义一致）。
     *
     * 两个抽屉互斥：打开批注前先关目录，否则两个遮罩叠在一起、返回键的归属会变得靠运气。
     */
    private fun showAnnotationList() {
        if (::tocDrawer.isInitialized && tocDrawer.isShowing) tocDrawer.hide()
        if (annotationDrawer.isShowing) {
            annotationDrawer.hide()
            return
        }
        annotationDrawer.show(annotationItems())
    }

    /** 数据变更后刷新已打开的抽屉（未打开时无操作，避免无谓构建视图）。 */
    private fun refreshAnnotationDrawer() {
        if (!::annotationDrawer.isInitialized || !annotationDrawer.isShowing) return
        annotationDrawer.show(annotationItems())
    }

    /** 行 → store 记录（ink 汇总行在 EPUB 侧不存在，保留同一套判定以便将来对齐）。 */
    private fun annotationsForRow(row: AnnotationRow): List<BookAnnotation> {
        val all = annotationStore.list(effectiveKey)
        return if (row.id == AnnotationGrouping.INK_SUMMARY_ID) {
            all.filter { it.kind == AnnotationGrouping.KIND_INK }
        } else {
            all.filter { "epub:${it.id}" == row.id }
        }
    }

    /**
     * 点击条目 → 跳转。
     *
     * 两级降级：
     * 1. location 是定稿形态 `chapter:<i>@<s>-<e>` → 跳章 + **章内按字符偏移滚动**；
     * 2. 旧记录（location 为空或 `chapter-<n>` 解析不出）→ 用本地 `chapterIndex` 只跳章。
     *
     * 章内定位失败（WebView 未就绪 / 偏移超出文本流）不报错，等价于「跳到章首」。
     */
    private fun jumpToAnnotation(row: AnnotationRow) {
        val target = annotationsForRow(row).firstOrNull() ?: return
        annotationDrawer.hide()
        val parsed = LocationCodec.parse(target.location)
        if (parsed is LocationCodec.Parsed.Chapter) {
            jumpToChapterWithOffset(parsed.spineIndex, parsed.startOffset)
        } else {
            jumpToChapter(target.chapterIndex)
        }
    }

    /** 跳章 + 尝试章内定位（偏移 <= 0 时只跳章，省一次 JS 往返）。 */
    private fun jumpToChapterWithOffset(chapterIndex: Int, startOffset: Int) {
        jumpToChapter(chapterIndex)
        if (startOffset <= 0) return
        val attempt = Runnable {
            LocationScroll.scrollTo(chapterWebView(chapterIndex), startOffset)
        }
        // 两次尝试：第一次覆盖「该章 WebView 已就绪（同章跳转）」，第二次兜住「刚切章、页面还在加载」
        scrollView.postDelayed(attempt, WEBVIEW_LOCATE_FIRST_DELAY_MS)
        scrollView.postDelayed(attempt, WEBVIEW_LOCATE_SECOND_DELAY_MS)
    }

    /**
     * 取某章的 WebView（章内定位用）。
     *
     * 两种翻页模式的承载方式不同：竖向模式 [scrollView] 的每个 item 就是 WebView；
     * 横向模式 [pager] 的每个 item 是承载 [ChapterFragment] 的容器 View，需再找
     * `R.id.chapterWebView`（该 id 属既有资源，不新增）。
     */
    private fun chapterWebView(index: Int): WebView? {
        val host = if (pageMode == ReaderPageMode.VERTICAL) {
            scrollView
        } else {
            pager.getChildAt(0) as? RecyclerView
        } ?: return null
        val item = host.findViewHolderForAdapterPosition(index)?.itemView ?: return null
        return (item as? WebView) ?: item.findViewById(R.id.chapterWebView)
    }

    /**
     * 编辑便签：与「添加批注」同款对话框，预填现有备注与选中原文。
     *
     * 保存后置 `dirty = true` 并异步推送。**只改 `text`，不改 `kind`**：备注是有无内容的问题，
     * 与标注类型正交——原本的 `highlight` 不会因为写了备注就变成 `note`（与 PDF 侧一致）。
     */
    private fun editAnnotationRow(row: AnnotationRow) {
        val target = annotationsForRow(row).firstOrNull() ?: return
        val input = EditText(this).apply {
            setText(target.note)
            hint = getString(R.string.reader_annotation_hint)
            minLines = 3
        }
        val container = FrameLayout(this).apply {
            setPadding(48, 32, 48, 0)
            addView(
                input,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        val builder = AlertDialog.Builder(this)
            .setTitle("编辑批注")
            .setView(container)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val note = input.text?.toString()?.trim().orEmpty()
                if (note.isEmpty()) return@setPositiveButton
                annotationStore.update(
                    // 只替换 text：kind 保持原值（加备注不改类型）
                    target.copy(note = note, dirty = true),
                )
                enqueuePushAnnotations()
                refreshAnnotationDrawer()
            }
            .setNegativeButton(android.R.string.cancel, null)
        // 选中原文为空时不留一行空白 message
        if (target.selectedText.isNotBlank()) builder.setMessage(target.selectedText.take(200))
        builder.show()
    }

    /**
     * 删除一条批注。
     *
     * **不要重复移除**：装配了 [syncManager] 时，本地移除与 `pendingDeletes` 入队都由
     * `SyncManager.deleteAnnotation` 完成（`serverId == null` 的记录不入队、不发 DELETE）。
     * 未装配同步（服务端未配置）时才由本方法直接删本地，并把 `serverId` 落进队列等下次 flush。
     */
    private fun deleteAnnotationRow(row: AnnotationRow) {
        val target = annotationsForRow(row).firstOrNull() ?: return
        val manager = syncManager
        if (manager != null) {
            manager.deleteAnnotation(effectiveKey, target)
            enqueuePushDeletes()
        } else {
            annotationStore.remove(effectiveKey, target.id)
            val serverId = target.serverId
            val identity = uid
            if (serverId != null && !identity.isNullOrBlank()) {
                pendingDeletes.add(identity, serverId)
            }
        }
        refreshAnnotationDrawer()
    }

    /** 异步 flush 待删队列（无同步管理器时直接返回，零网络行为）。 */
    private fun enqueuePushDeletes() {
        val manager = syncManager ?: return
        val id = effectiveKey
        val executor = syncExecutor ?: return
        // 同 [enqueuePushProgress]：shutdown() 之后提交会被拒绝，异常一并兜住。
        runCatching {
            executor.execute {
                runCatching { manager.pushDeletes(id) }
                    .onFailure { Log.w(TAG, "推送批注删除失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
    }

    // ---- 进度 ----

    private fun persistProgress(chapterIndex: Int) {
        if (effectiveKey.isBlank() || book == null) return
        progressStore.save(
            ReadingProgress(
                documentId = effectiveKey,
                chapterIndex = chapterIndex,
                scrollY = scrollByChapter[chapterIndex] ?: 0,
            ),
        )
        // 本地已写成功；远端推送统一交给 onStop（每页推送会导致请求爆炸，见推送方法的说明）。
    }

    // ---- 旧键清理 ----

    /**
     * 旧键一次性清理：进度与批注两个 prefs 文件各自用 `legacy_cleared` 标记控制，互不影响。
     *
     * 同名 prefs 文件由系统缓存为同一实例，故此处读标记与 Store 内部的读写看到同一份数据。
     */
    private fun clearLegacyOnce() {
        clearLegacyOnceFor(ReadingProgressStore.PREFS_NAME) { progressStore.clearLegacy() }
        clearLegacyOnceFor(AnnotationStore.PREFS_NAME) { annotationStore.clearLegacy() }
    }

    private fun clearLegacyOnceFor(prefsName: String, clear: () -> Int) {
        val prefs = getSharedPreferences(prefsName, MODE_PRIVATE)
        if (prefs.getBoolean(LegacyKeys.CLEARED_FLAG, false)) return
        clear()
        prefs.edit().putBoolean(LegacyKeys.CLEARED_FLAG, true).apply()
    }

    // ---- 批注 ----

    private fun addAnnotationFromSelection() {
        if (pageMode == ReaderPageMode.VERTICAL) {
            // 竖向模式无 Fragment：直接从当前可见章的 WebView 取选区。
            val web = (scrollView.findViewHolderForAdapterPosition(visibleChapterIndex)
                as? ChapterScrollAdapter.ChapterHolder)?.webView
            if (web == null) {
                Toast.makeText(this, R.string.reader_annotation_no_page, Toast.LENGTH_SHORT).show()
                return
            }
            readSelection(web) { selected, range -> onSelectionCaptured(visibleChapterIndex, selected, range) }
            return
        }
        val fragment = currentChapterFragment()
        if (fragment == null) {
            Toast.makeText(this, R.string.reader_annotation_no_page, Toast.LENGTH_SHORT).show()
            return
        }
        fragment.selection { selected, range ->
            onSelectionCaptured(fragment.chapterIndex, selected, range)
        }
    }

    /**
     * 选区 → 弹窗：空选区给提示；非空进便签对话框。
     *
     * [range] 为 `null` 表示取不到章内偏移（旧 WebView / JS 失败），此时仍可创建批注，
     * location 退回旧形态 `chapter-<chapterIndex>`（见 [SelectionPayload.locationFor]）。
     */
    private fun onSelectionCaptured(chapterIndex: Int, selectedText: String, range: SelectionRange?) {
        if (selectedText.isBlank()) {
            Toast.makeText(this, R.string.reader_annotation_empty_selection, Toast.LENGTH_SHORT).show()
        } else {
            showAnnotationDialog(chapterIndex, selectedText, range)
        }
    }

    private fun currentChapterFragment(): ChapterFragment? = supportFragmentManager.fragments
        .filterIsInstance<ChapterFragment>()
        .firstOrNull { it.chapterIndex == pager.currentItem }

    private fun showAnnotationDialog(
        chapterIndex: Int,
        selectedText: String,
        range: SelectionRange?,
    ) {
        val input = EditText(this).apply {
            hint = getString(R.string.reader_annotation_hint)
            minLines = 3
        }
        val container = FrameLayout(this).apply {
            setPadding(48, 32, 48, 0)
            addView(
                input,
                FrameLayout.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.WRAP_CONTENT,
                ),
            )
        }
        AlertDialog.Builder(this)
            .setTitle(R.string.reader_annotation_title)
            .setMessage(selectedText.take(200))
            .setView(container)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val note = input.text.toString()
                annotationStore.add(
                    BookAnnotation(
                        documentId = effectiveKey,
                        chapterIndex = chapterIndex,
                        selectedText = selectedText,
                        note = note,
                        // 偏移可用 → chapter:<i>@<s>-<e>；不可用 → 旧形态 chapter-<i>（不崩溃）
                        location = SelectionPayload.locationFor(chapterIndex, range),
                        // 选中即 highlight：备注只写 text，不参与 kind（两维正交，与 PDF 侧一致）
                        kind = AnnotationGrouping.kindForSelection(
                            hasSelectedText = selectedText.isNotBlank(),
                            hasNote = note.isNotBlank(),
                        ),
                    ),
                )
                // 本地已落盘，再异步推送（失败静默，下次推送会因幂等去重补齐）。
                enqueuePushAnnotations()
                Toast.makeText(this, R.string.reader_annotation_saved, Toast.LENGTH_SHORT).show()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    // ---- 错误 ----

    private fun fail(message: String) {
        Toast.makeText(this, getString(R.string.reader_open_failed, message), Toast.LENGTH_LONG).show()
        finish()
    }

    private fun epubUriFromIntent(): Uri? {
        val raw = intent.getStringExtra(EXTRA_EPUB_URI) ?: return null
        return Uri.parse(raw)
    }

    /** ViewPager2 适配器：每章一个 [ChapterFragment]。 */
    private class ChapterPagerAdapter(
        activity: FragmentActivity,
        private val count: Int,
    ) : FragmentStateAdapter(activity) {

        override fun getItemCount(): Int = count

        override fun createFragment(position: Int): ChapterFragment = ChapterFragment.newInstance(position)
    }

    companion object {
        /** 日志标签（本类此前无日志，同步失败是首类需要记录的事件）。 */
        private const val TAG = "EpubReader"

        const val EXTRA_EPUB_PATH = "extra_epub_path"
        const val EXTRA_EPUB_URI = "extra_epub_uri"

        /** Intent 中携带服务端 uid 的键（可选；为空则退回内容哈希键）。 */
        const val EXTRA_UID = "extra_reader_uid"

        /** 单击 → 切换浮层的延迟（毫秒）：跨过双击判定窗口，避免双击缩放第一击触发切换。 */
        private const val TAP_TOGGLE_DELAY_MS = 250L

        /** 章内定位的第一次尝试延迟（毫秒）：同章跳转时 WebView 已就绪，等一次主线程排空即可。 */
        private const val WEBVIEW_LOCATE_FIRST_DELAY_MS = 250L

        /** 章内定位的第二次尝试延迟（毫秒）：兜住「刚切章、页面仍在加载」的情况。 */
        private const val WEBVIEW_LOCATE_SECOND_DELAY_MS = 800L

        /**
         * 顶部浮层的垂直基础 padding（dp）：与 `activity_epub_reader.xml` 的
         * `epubTopChrome` `paddingVertical` 对齐。
         */
        private const val CHROME_BASE_PADDING_DP = 2f

        /**
         * 底部浮层的垂直基础 padding（dp）：与 `activity_epub_reader.xml` 的
         * `epubBottomChrome` `paddingVertical` 对齐（该浮层是 4dp，与顶部不同）。
         */
        private const val BOTTOM_CHROME_BASE_PADDING_DP = 4f

        /** 以本地文件路径打开（示例 epub 用）。[uid] 非空时写入 [EXTRA_UID]。 */
        fun intentForFile(context: Context, file: File, uid: String? = null): Intent =
            Intent(context, EpubReaderActivity::class.java)
                .putExtra(EXTRA_EPUB_PATH, file.absolutePath)
                .apply { if (uid != null) putExtra(EXTRA_UID, uid) }

        /** 以 content Uri 打开（SAF 选择的 epub 用）。[uid] 非空时写入 [EXTRA_UID]。 */
        fun intentForUri(context: Context, uri: Uri, uid: String? = null): Intent =
            Intent(context, EpubReaderActivity::class.java)
                .putExtra(EXTRA_EPUB_URI, uri.toString())
                .apply { if (uid != null) putExtra(EXTRA_UID, uid) }
    }
}
