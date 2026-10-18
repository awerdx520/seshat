package com.seshat.app.reader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
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
import com.seshat.app.settings.SettingsStore
import com.seshat.app.sync.EpubLocalSyncStore
import com.seshat.app.sync.EpubSyncMapper
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.RestClientSyncAdapter
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SyncManager
import com.seshat.app.sync.createReaderSync
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * epub 阅读界面（MVP）。
 *
 * - 章节内容：WebView 显示当前章节 HTML，资源经 https 虚拟域（[EPUB_ASSET_DOMAIN]）由内存 zip 提供；
 * - 章节导航：两种模式（[ReaderPageMode]，由设置页决定，**只在打开阅读器时生效**）：
 *   - [ReaderPageMode.HORIZONTAL]：`ViewPager2` 左右滑动，每章一页（[ChapterPagerAdapter] + [ChapterFragment]）；
 *   - [ReaderPageMode.VERTICAL]：`RecyclerView` 竖向连续滚动，章与章首尾相接（[ChapterScrollAdapter]）；
 *   两种容器同时存在于布局中，按模式只显示其一，底部「上一章/下一章」按钮按模式分流。
 * - 顶部显示「第 n/N 章 · 标题」；
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

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_epub_reader)

        // 模式与字号只在打开阅读器时读取一次（设置页改动下次进来生效）。
        val prefs = AppPreferences.open(this)
        pageMode = prefs.pageMode()
        textZoom = prefs.textZoom()

        chapterTitleView = findViewById(R.id.chapterTitleView)
        pager = findViewById(R.id.chapterPager)
        scrollView = findViewById(R.id.chapterScrollView)
        progressStore = ReadingProgressStore(this)
        annotationStore = AnnotationStore(this)
        uid = intent.getStringExtra(EXTRA_UID)?.trim()?.takeIf { it.isNotEmpty() }
        // 旧键一次性清理（幂等；每 prefs 文件各自标记，只跑第一次）
        clearLegacyOnce()

        findViewById<Button>(R.id.prevChapterButton).setOnClickListener { moveBy(-1) }
        findViewById<Button>(R.id.nextChapterButton).setOnClickListener { moveBy(1) }
        findViewById<Button>(R.id.annotateButton).setOnClickListener { addAnnotationFromSelection() }

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
        super.onStop()
    }

    override fun onDestroy() {
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
        ) ?: return
        syncManager = manager
        val executor = Executors.newSingleThreadExecutor().also { syncExecutor = it }
        executor.execute {
            runCatching {
                // 批注：合并（幂等，按 location + text 去重），远端新增写入本地
                manager.pullAnnotations(id)
                // 进度：仅本地没有进度时拉取（避免覆盖本机正在读的位置）
                if (progressStore.load(id) == null) manager.pullProgress(id)
                // 本地已有进度：推送上去（服务端 updated_at 会因此前进）
                manager.pushProgress(id)
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
                runCatching { manager.pushProgress(id) }
                    // pushProgress 返回 Progress?：不抛异常即视为推送成功，此时才记住该位置。
                    .onSuccess { lastPushedPosition = position }
                    .onFailure { Log.w(TAG, "推送阅读进度失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
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
    }

    /**
     * 由竖向滚动位置推导当前章节与章内偏移，更新标题并持久化。
     *
     * **当前章**取「覆盖视口中心的那一项」（多章同屏时 firstVisible 可能仍是上一章）；
     * **章内偏移**取中心项自身顶部已滚出视口的像素（`-centerView.top`），
     * 不得复用「首项锚点换算」（`ScrollProgressMath` 旧的 first 项路径）的 offset：
     * 那是相对 first 项的滚出量，中心项不是 first 时会错位。
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
        // 可视中心章；无可见项时保持原章不动
        val chapterIndex = ScrollProgressMath.visibleCenterPosition(bounds, scrollView.height / 2)
            ?: return
        val centerView = layoutManager.findViewByPosition(chapterIndex) ?: return
        val scrollY = (-centerView.top).coerceAtLeast(0)

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

    // ---- 导航与标题 ----

    private fun moveBy(delta: Int) {
        val count = chapterCount()
        if (count == 0) return
        val current = if (pageMode == ReaderPageMode.VERTICAL) visibleChapterIndex else pager.currentItem
        val target = (current + delta).coerceIn(0, count - 1)
        if (target == current) return
        if (pageMode == ReaderPageMode.VERTICAL) {
            scrollView.smoothScrollToPosition(target)
        } else {
            pager.setCurrentItem(target, true)
        }
    }

    private fun updateChapterTitle(index: Int) {
        val chapters = book?.chapters ?: return
        val chapter = chapters.getOrNull(index) ?: return
        chapterTitleView.text = getString(
            R.string.reader_chapter_title,
            index + 1,
            chapters.size,
            chapter.title,
        )
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
            web.evaluateJavascript("(function(){return String(window.getSelection());})()") { raw ->
                val selected = decodeJsString(raw)
                if (selected.isBlank()) {
                    Toast.makeText(this, R.string.reader_annotation_empty_selection, Toast.LENGTH_SHORT).show()
                } else {
                    showAnnotationDialog(visibleChapterIndex, selected)
                }
            }
            return
        }
        val fragment = currentChapterFragment()
        if (fragment == null) {
            Toast.makeText(this, R.string.reader_annotation_no_page, Toast.LENGTH_SHORT).show()
            return
        }
        fragment.selectedText { selected ->
            if (selected.isBlank()) {
                Toast.makeText(this, R.string.reader_annotation_empty_selection, Toast.LENGTH_SHORT).show()
            } else {
                showAnnotationDialog(fragment.chapterIndex, selected)
            }
        }
    }

    private fun currentChapterFragment(): ChapterFragment? = supportFragmentManager.fragments
        .filterIsInstance<ChapterFragment>()
        .firstOrNull { it.chapterIndex == pager.currentItem }

    private fun showAnnotationDialog(chapterIndex: Int, selectedText: String) {
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
                annotationStore.add(
                    BookAnnotation(
                        documentId = effectiveKey,
                        chapterIndex = chapterIndex,
                        selectedText = selectedText,
                        note = input.text.toString(),
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
