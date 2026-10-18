package com.seshat.app.reader

import android.content.Context
import android.content.Intent
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.util.Log
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.PagerSnapHelper
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.ReaderPageMode
import com.seshat.app.settings.SettingsStore
import com.seshat.app.sync.PdfLocalSyncStore
import com.seshat.app.sync.PdfSyncMapper
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.RestClientSyncAdapter
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SyncManager
import com.seshat.app.sync.createReaderSync
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * PDF 阅读器（M3.3 MVP / M9.2 支持竖向连续滚动）。
 *
 * 渲染方案：使用 Android 系统内置的 [PdfRenderer]（API 21+，无需第三方 JNI 库），
 * 逐页渲染为 Bitmap，交由 [PdfPageAdapter] 在 [RecyclerView] 中显示，
 * 底部 [TextView] 显示「当前页 / 总页数」。
 *
 * 翻页模式由 [AppPreferences.pageMode] 决定，**只在打开阅读器时生效**：
 * - [ReaderPageMode.HORIZONTAL]：线性横向 + [PagerSnapHelper]，整页吸附横滑；
 * - [ReaderPageMode.VERTICAL]：线性竖向连续滚动，无吸附。
 *
 * 入口：Intent 携带 [EXTRA_URI]（`content://` 或 `file://` 的 PDF Uri），
 * 可选携带 [EXTRA_UID]（服务端 uid；非空时以其作为 Store 键），通过 [intent] 工厂方法构造。
 *
 * 持久化：
 * - 阅读进度 → [PdfProgressStore]，键 `pdf_progress_<key>`。
 * - 批注     → [PdfAnnotationStore]，键 `pdf_annotations_<key>`。
 * - 笔迹     → [PdfInkStore]，键 `pdf_ink_<key>`。
 * 三者共用 `SharedPreferences("pdf_reader")`，与 epub 侧键空间隔离；
 * `<key>` 为服务端 uid（有则用）或 uri 字符串（无则退回）。
 */
class PdfReaderActivity : AppCompatActivity(), PdfInkHost {

    private lateinit var recycler: RecyclerView
    private lateinit var pageIndicator: TextView

    private lateinit var layoutManager: LinearLayoutManager
    private lateinit var pageMode: ReaderPageMode

    private var renderer: PdfRenderer? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var adapter: PdfPageAdapter? = null
    private var docId: String = ""

    /**
     * 服务端文档 uid（Intent 携带；为空表示未登记/离线打开）。
     *
     * 与 [docId] 的区别：[docId] 在无 uid 时退回 uri 字符串，而同步只认 uid——
     * 故必须单独保留 uid 以判断「是否具备同步身份」。
     */
    private var uid: String? = null

    /**
     * 阅读状态同步管理器。
     *
     * 仅当「有 uid」且「服务端已配置」时非 `null`（见 [setupSync]）。
     */
    private var syncManager: SyncManager<PdfProgress, PdfAnnotation>? = null

    /**
     * 同步专用单线程（与页面渲染线程隔离，避免网络阻塞渲染）。
     *
     * 单线程保证同一文档的拉取/推送串行，避免顺序错乱。
     */
    private var syncExecutor: ExecutorService? = null

    /**
     * 上次「已成功推送」的页码字符串（`page.toString()`，与 [PdfSyncMapper.encodePosition] 一致）。
     *
     * 只在同步线程（[syncExecutor] 的单线程）内读写，故无需额外同步。用途见下方推送方法的说明。
     */
    private var lastPushedPosition: String? = null

    /** 最后一页索引（`pageCount - 1`，至少为 0）。 */
    private var lastPage: Int = 0

    /** 上次已上报的页（避免滚动过程中重复写进度、重复刷新指示器）。 */
    private var lastReportedPage: Int = -1

    private lateinit var progressStore: PdfProgressStore
    private lateinit var annotationStore: PdfAnnotationStore
    private lateinit var inkStore: PdfInkStore

    private lateinit var inkToggleButton: Button
    private lateinit var inkUndoButton: Button
    private lateinit var inkClearButton: Button
    private lateinit var prevPageButton: Button
    private lateinit var nextPageButton: Button
    private lateinit var chrome: View

    /** 手写模式开关（旋转经 savedInstanceState 恢复）。 */
    private var inkEnabled: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pdf_reader)

        // 先绑定视图，保证后续任何提前 finish 时 onDestroy 访问安全。
        recycler = findViewById(R.id.pdfPager)
        pageIndicator = findViewById(R.id.pdfPageIndicator)
        chrome = findViewById(R.id.pdfChrome)
        inkToggleButton = findViewById(R.id.pdfInkToggleButton)
        inkUndoButton = findViewById(R.id.pdfInkUndoButton)
        inkClearButton = findViewById(R.id.pdfInkClearButton)
        prevPageButton = findViewById(R.id.pdfPrevPageButton)
        nextPageButton = findViewById(R.id.pdfNextPageButton)

        // 浮层贴底：按系统导航栏/刘海补底部 padding，避免按钮被遮挡
        ViewCompat.setOnApplyWindowInsetsListener(chrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                view.paddingLeft,
                view.paddingTop,
                view.paddingRight,
                bars.bottom + (INITIAL_CHROME_PADDING_DP * resources.displayMetrics.density).toInt(),
            )
            insets
        }

        // 手写开关跨旋转恢复：否则转屏后手写层会静默关闭。
        inkEnabled = savedInstanceState?.getBoolean(STATE_INK_ENABLED) ?: false

        val uri = extractUri()
        if (uri == null) {
            toast(getString(R.string.pdf_error_no_uri))
            finish()
            return
        }
        // 键选择的唯一落点：有服务端 uid 用 uid，否则用 uri 字符串（M7 之前的行为）
        uid = intent.getStringExtra(EXTRA_UID)?.trim()?.takeIf { it.isNotEmpty() }
        docId = uid ?: uri.toString()

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        progressStore = PdfProgressStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
            keys = { prefs.all.keys },
            remove = { key -> prefs.edit().remove(key).apply() },
        )
        annotationStore = PdfAnnotationStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
            keys = { prefs.all.keys },
            remove = { key -> prefs.edit().remove(key).apply() },
        )
        inkStore = PdfInkStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
            keys = { prefs.all.keys },
            remove = { key -> prefs.edit().remove(key).apply() },
        )
        // 旧键一次性清理（三个 store 共用 pdf_reader prefs，故共用一个标记）
        clearLegacyOnce()

        findViewById<Button>(R.id.pdfAddAnnotation).setOnClickListener { promptAnnotation() }
        inkToggleButton.setOnClickListener { toggleInk() }
        inkUndoButton.setOnClickListener { undoInk() }
        inkClearButton.setOnClickListener { clearInk() }
        prevPageButton.setOnClickListener { movePage(-1) }
        nextPageButton.setOnClickListener { movePage(1) }

        val pdf = openRenderer(uri)
        if (pdf == null) {
            toast(getString(R.string.pdf_error_open))
            finish()
            return
        }
        renderer = pdf
        lastPage = (pdf.pageCount - 1).coerceAtLeast(0)

        // 模式在打开阅读器时读取一次（设置页改动下次生效）。
        pageMode = AppPreferences.open(this).pageMode()
        val vertical = pageMode == ReaderPageMode.VERTICAL
        layoutManager = LinearLayoutManager(
            this,
            if (vertical) LinearLayoutManager.VERTICAL else LinearLayoutManager.HORIZONTAL,
            false,
        )
        recycler.layoutManager = layoutManager
        if (!vertical) {
            // 横向模式用 PagerSnapHelper 实现整页吸附（等价传统翻页器的手感）。
            PagerSnapHelper().attachToRecyclerView(recycler)
        }

        adapter = PdfPageAdapter(
            pdf,
            renderWidth(pdf),
            pageMode,
            inkHost = this,
            defaultItemHeight = resources.displayMetrics.heightPixels,
        )
        recycler.adapter = adapter
        recycler.addOnScrollListener(object : RecyclerView.OnScrollListener() {
            override fun onScrolled(recyclerView: RecyclerView, dx: Int, dy: Int) {
                updateCurrentPage()
            }
        })
        // 点击翻页：左右两侧点击翻页、中间点击切换工具栏。
        installTapPaging()

        // 恢复进度：越界夹紧到合法页范围。
        val startPage = progressStore.load(docId)?.page?.coerceIn(0, lastPage) ?: 0
        if (vertical) {
            layoutManager.scrollToPositionWithOffset(startPage, 0)
        } else {
            recycler.scrollToPosition(startPage)
        }
        // 初始定位即视为「已上报」，避免首次滚动回调把同一页重复写一遍。
        lastReportedPage = startPage
        updateIndicator(startPage)
        adapter?.preload(startPage)
        updateInkChrome()

        // Store 与 docId 均就绪后再装配同步（内部三条守卫，任一不满足即完全跳过网络）。
        // 放在恢复进度之后：拉取只会写本地 Store，不会打断已完成的定位。
        setupSync()
    }

    /**
     * 装配阅读状态同步（进度 + 批注）。
     *
     * **三条守卫**（任一不满足即安静返回，不提示、不报错）：
     * 1. [uid] 非空——无 uid 时服务端 URL 里没有稳定身份，进度/批注无法归属；
     * 2. `SettingsStore.toConfig()` 非空——服务端地址与访问令牌缺一不可；
     * 3. [createReaderSync] 非空——上述两条的最终裁决点，未通过时不会构造 `RestClient`。
     *
     * **失败语义**：所有网络异常在 [syncExecutor] 线程内被 `runCatching` 吞掉并记一条 warn 日志——
     * 阅读是本地优先功能，同步失败不得阻断或弹窗打扰。
     *
     * **已知限制**：拉取到的进度只写入本地 Store，**不立即跳转页面**（当前页已按本地进度恢复，
     * 中途跳转会让正在读的用户丢失位置）；远端进度在下次打开本文档时生效。
     *
     * **不参与同步**：手写笔迹（[inkStore]）不走状态同步 API，保持纯本地。
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
            store = PdfLocalSyncStore(progressStore, annotationStore),
            mapper = PdfSyncMapper(),
        ) ?: return
        syncManager = manager
        val executor = Executors.newSingleThreadExecutor().also { syncExecutor = it }
        executor.execute {
            runCatching {
                // 批注：合并（幂等，按 location + text 去重），远端新增写入本地
                manager.pullAnnotations(id)
                // 进度：仅本地没有进度时拉取（避免覆盖本机正在读的页码）
                if (progressStore.load(id) == null) manager.pullProgress(id)
                // 本地已有进度：推送上去（服务端 updated_at 会因此前进）
                manager.pushProgress(id)
            }.onFailure { Log.w(TAG, "拉取阅读状态失败（已忽略）", it) }
        }
    }

    /**
     * 异步推送一次进度（无同步管理器时直接返回，零网络行为）。
     *
     * **为什么不在 [saveProgress] 里推**：该方法每次页切换/滚动定位都会执行，若在其中推送，
     * 翻 100 页就会向 `PUT /api/progress/{uid}` 排队 100 次请求（单线程 executor 串行积压，
     * 服务端被无意义写爆）。故改为只在 [onStop] 推一次——「离开阅读器即同步」语义合理。
     *
     * **为什么比较放在 executor 内**：位置取值、与 [lastPushedPosition] 比较、推送三者都在
     * 同步线程执行——主线程零网络、也不做额外的 prefs 读；单线程内读写天然串行，
     * 不存在主线程与同步线程之间的竞态。该「同值跳过」是**防抖**（不重复推同一页），
     * 不是严格节流（不做时间窗限流）。
     */
    private fun enqueuePushProgress() {
        val manager = syncManager ?: return
        val id = docId
        val executor = syncExecutor ?: return
        // [onDestroy] 里的 shutdown() 之后 executor 拒绝新任务（RejectedExecutionException）：
        // 正常时序下 onStop 先于 onDestroy 不会命中，但旋转屏/异常销毁等边缘时序可能让提交落在
        // shutdown 之后——兜住异常，同步失败不得影响阅读器销毁。
        runCatching {
            executor.execute {
                // 以本地已落盘的进度为准（saveProgress 已先写本地），读不到说明还没有进度。
                val position = progressStore.load(id)?.page?.toString() ?: return@execute
                if (position == lastPushedPosition) return@execute
                runCatching { manager.pushProgress(id) }
                    // pushProgress 返回 Progress?：不抛异常即视为推送成功，此时才记住该页。
                    .onSuccess { lastPushedPosition = position }
                    .onFailure { Log.w(TAG, "推送阅读进度失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
    }

    /** 新增批注后异步推送（无同步管理器时直接返回，零网络行为）。 */
    private fun enqueuePushAnnotations() {
        val manager = syncManager ?: return
        val id = docId
        val executor = syncExecutor ?: return
        // 同 [enqueuePushProgress]：shutdown() 之后提交会被拒绝，异常一并兜住。
        runCatching {
            executor.execute {
                runCatching { manager.pushAnnotations(id) }
                    .onFailure { Log.w(TAG, "推送批注失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
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

        // 先解绑，避免销毁过程中仍有新的绑定提交渲染任务。
        if (::recycler.isInitialized) {
            recycler.clearOnScrollListeners()
            recycler.adapter = null
        }
        adapter?.shutdown()
        adapter = null
        renderer?.close()
        fileDescriptor?.close()
        renderer = null
        fileDescriptor = null
    }

    override fun onSaveInstanceState(outState: Bundle) {
        super.onSaveInstanceState(outState)
        outState.putBoolean(STATE_INK_ENABLED, inkEnabled)
    }

    /** 读取 Intent 中的 PDF Uri，兼容高低版本 API。 */
    private fun extractUri(): Uri? = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        intent.getParcelableExtra(EXTRA_URI, Uri::class.java)
    } else {
        @Suppress("DEPRECATION")
        intent.getParcelableExtra(EXTRA_URI)
    }

    /** 打开 PDF 文件描述符并创建 [PdfRenderer]，失败返回 `null`。 */
    private fun openRenderer(uri: Uri): PdfRenderer? {
        val pfd = try {
            contentResolver.openFileDescriptor(uri, "r")
        } catch (e: IOException) {
            null
        } catch (e: SecurityException) {
            null
        }
        if (pfd == null) return null
        return try {
            val pdf = PdfRenderer(pfd)
            fileDescriptor = pfd
            pdf
        } catch (e: IOException) {
            pfd.close()
            null
        }
    }

    /**
     * 渲染宽度：竖向模式或竖屏用屏幕宽；横屏 + 横向翻页时按可用高度 × 首页宽高比（夹紧到屏幕宽），
     * 让页面尽量铺满、减少左右留白并提升有效分辨率。
     *
     * **调用时机**：必须在 [PdfPageAdapter] 构造**之前**调用（此刻渲染线程尚未创建，
     * 主线程读取首页尺寸不会与后台渲染并发）。`openPage` 不渲染，耗时通常 <5ms。
     */
    private fun renderWidth(renderer: PdfRenderer): Int {
        val metrics = resources.displayMetrics
        val screenWidth = if (metrics.widthPixels > 0) metrics.widthPixels else DEFAULT_RENDER_WIDTH
        val portrait = metrics.widthPixels <= metrics.heightPixels
        if (pageMode == ReaderPageMode.VERTICAL || portrait) return screenWidth

        // 横屏 + 横向翻页：用首页宽高比估算「高度铺满」时所需的宽度
        val aspect = try {
            renderer.openPage(0).use { page ->
                page.width.toFloat() / page.height.toFloat()
            }
        } catch (e: Exception) {
            return screenWidth
        }
        if (aspect <= 0f) return screenWidth
        val availableHeight = metrics.heightPixels * 0.92f
        val candidate = (availableHeight * aspect).toInt()
        return if (candidate > 0) candidate.coerceAtMost(screenWidth) else screenWidth
    }

    /** 当前页（0-based）：首个可见项；无可见项（尚未布局）时返回 0。 */
    private fun firstVisiblePage(): Int =
        layoutManager.findFirstVisibleItemPosition().coerceAtLeast(0)

    /**
     * 由滚动位置更新页码指示与进度，并预取邻近页。
     *
     * 可见项顶部偏移通过 [ScrollProgressMath] 归一为「页 + 页内偏移」语义：
     * 首个可见项顶部在视口下方时（`itemTop > 0`）真实阅读位置落在上一页内部，
     * 此时进度记在上一页，与横向模式（页对齐）语义保持一致。
     */
    private fun updateCurrentPage() {
        val firstVisible = layoutManager.findFirstVisibleItemPosition()
        // 尚未布局或无可附着子项：此时位置不可信，直接跳过，避免误写第 0 页。
        if (firstVisible == RecyclerView.NO_POSITION) return

        val top = layoutManager.findViewByPosition(firstVisible)?.top ?: 0
        // 上一项（已附着的 View）的实际高度；未附着时传 0，偏移退化为 itemTop。
        val previousItemHeight = if (firstVisible > 0) {
            layoutManager.findViewByPosition(firstVisible - 1)?.height ?: 0
        } else {
            0
        }
        val anchor = ScrollProgressMath.progressFromViewport(firstVisible, top, previousItemHeight)
        val position = anchor.position.coerceIn(0, lastPage)
        if (position == lastReportedPage) return
        lastReportedPage = position
        updateIndicator(position)
        saveProgress(position)
        adapter?.preload(position)
        // 页面切换后「撤销 / 清除本页」的可见性要跟着当前页的笔迹状态变化。
        updateInkChrome()
    }

    private fun updateIndicator(position: Int) {
        val total = renderer?.pageCount ?: 0
        pageIndicator.text = getString(R.string.pdf_page_indicator, position + 1, total)
    }

    private fun saveProgress(position: Int) {
        progressStore.save(docId, PdfProgress(page = position, updatedAt = System.currentTimeMillis()))
        // 本地已写成功；远端推送统一交给 onStop（每页推送会导致请求爆炸，见推送方法的说明）。
    }

    /** 弹出输入框，为当前页添加一条文本批注。 */
    private fun promptAnnotation() {
        val input = EditText(this).apply { hint = getString(R.string.pdf_annotation_hint) }
        AlertDialog.Builder(this)
            .setTitle(getString(R.string.pdf_annotation_title, firstVisiblePage() + 1))
            .setView(input)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val text = input.text?.toString()?.trim().orEmpty()
                if (text.isNotEmpty()) addAnnotation(text)
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    private fun addAnnotation(text: String) {
        val now = System.currentTimeMillis()
        val annotation = PdfAnnotation(
            id = annotationStore.nextId(docId),
            documentId = docId,
            location = "page:${firstVisiblePage() + 1}",
            text = text,
            createdAt = now,
            updatedAt = now,
        )
        annotationStore.add(annotation)
        // 本地已落盘，再异步推送（失败静默，下次推送会因幂等去重补齐）。
        enqueuePushAnnotations()
        toast(getString(R.string.pdf_annotation_saved, annotationStore.count(docId)))
    }

    // ---- PdfInkHost ----

    override fun inkStrokes(page: Int): List<InkStroke> = inkStore.strokes(docId, page)

    override fun onInkStrokeFinished(page: Int, stroke: InkStroke) {
        inkStore.appendStroke(docId, page, stroke)
        adapter?.refreshInk(page)
        updateInkChrome()
    }

    override fun isInkEnabled(): Boolean = inkEnabled

    // ---- 手写按钮 ----

    /** 切换手写模式；开启时显示翻页按钮（落笔占用点击与滑动，需按钮兜底翻页）。 */
    private fun toggleInk() {
        inkEnabled = !inkEnabled
        adapter?.setInkEnabled(inkEnabled)
        updateInkChrome()
        toast(getString(if (inkEnabled) R.string.pdf_ink_toggle_on else R.string.pdf_ink_toggle))
    }

    /** 撤销当前页最后一笔。 */
    private fun undoInk() {
        val page = firstVisiblePage()
        if (inkStore.undoLast(docId, page)) {
            adapter?.refreshInk(page)
        } else {
            toast(getString(R.string.pdf_ink_nothing_to_undo))
        }
        updateInkChrome()
    }

    /** 清除当前页全部笔迹。 */
    private fun clearInk() {
        val page = firstVisiblePage()
        inkStore.clearPage(docId, page)
        adapter?.refreshInk(page)
        updateInkChrome()
        toast(getString(R.string.pdf_ink_cleared))
    }

    /** 刷新手写相关控件的可见性与文案。 */
    private fun updateInkChrome() {
        inkToggleButton.setText(
            if (inkEnabled) R.string.pdf_ink_toggle_on else R.string.pdf_ink_toggle,
        )
        val hasInk = inkStore.hasInk(docId, firstVisiblePage())
        inkUndoButton.visibility = if (inkEnabled && hasInk) View.VISIBLE else View.GONE
        inkClearButton.visibility = if (inkEnabled && hasInk) View.VISIBLE else View.GONE
        // 手写时点击与滑动都被落笔占用，必须保留按钮翻页
        prevPageButton.visibility = if (inkEnabled) View.VISIBLE else View.GONE
        nextPageButton.visibility = if (inkEnabled) View.VISIBLE else View.GONE
    }

    // ---- 点击翻页 ----

    /**
     * 安装点击翻页：OnItemTouchListener + GestureDetector。
     *
     * 关键：onInterceptTouchEvent **恒返回 false**，只把事件喂给 GestureDetector，
     * 绝不拦截——否则会吞掉滑动与 PagerSnapHelper 的吸附。
     */
    private fun installTapPaging() {
        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                if (inkEnabled) return false // 落笔优先
                // 坐标先取值：事件对象在 post 之后可能已被系统复用。
                val tapX = e.x
                recycler.post { handleTap(tapX) }
                return true
            }
        })
        recycler.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: MotionEvent): Boolean {
                detector.onTouchEvent(e)
                return false
            }
        })
    }

    /** 处理单击：横向模式左 30% 上一页、右 30% 下一页，其余区域切换工具栏显隐。 */
    private fun handleTap(tapX: Float) {
        if (pageMode == ReaderPageMode.HORIZONTAL) {
            val width = recycler.width
            when {
                tapX < width * 0.3f -> movePage(-1)
                tapX > width * 0.7f -> movePage(1)
                else -> toggleChrome()
            }
        } else {
            toggleChrome()
        }
    }

    /** 翻页：横向用 scrollToPosition（立即跳转，避免与 PagerSnapHelper 的动画竞争）。 */
    private fun movePage(delta: Int) {
        val current = firstVisiblePage()
        val target = (current + delta).coerceIn(0, lastPage)
        if (target == current) return
        recycler.scrollToPosition(target)
    }

    /** 切换浮层工具栏显隐。 */
    private fun toggleChrome() {
        chrome.visibility = if (chrome.visibility == View.VISIBLE) View.GONE else View.VISIBLE
    }

    /**
     * 旧键一次性清理：三个 store 共用 `pdf_reader` prefs 文件，故共用一个 `legacy_cleared` 标记。
     *
     * 先全部清理再置位：若中途进程被杀，下次进入会重跑（清理本身幂等）。
     */
    private fun clearLegacyOnce() {
        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        if (prefs.getBoolean(LegacyKeys.CLEARED_FLAG, false)) return
        progressStore.clearLegacy()
        annotationStore.clearLegacy()
        inkStore.clearLegacy()
        prefs.edit().putBoolean(LegacyKeys.CLEARED_FLAG, true).apply()
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        /** 日志标签（本类此前无日志，同步失败是首类需要记录的事件）。 */
        private const val TAG = "PdfReader"

        /** Intent 中携带 PDF Uri 的键。 */
        const val EXTRA_URI: String = "com.seshat.app.reader.EXTRA_URI"

        /** Intent 中携带服务端 uid 的键（可选；为空则退回 uri 字符串键）。 */
        const val EXTRA_UID: String = "com.seshat.app.reader.EXTRA_UID"

        /** 与 epub 侧共享同一 SharedPreferences 文件，但键命名空间不同。 */
        const val PREFS_NAME: String = "pdf_reader"

        private const val DEFAULT_RENDER_WIDTH = 1080

        /** 浮层工具栏的初始内边距（dp），与布局 `activity_pdf_reader.xml` 中 `padding="6dp"` 对应。 */
        private const val INITIAL_CHROME_PADDING_DP = 6

        /** `savedInstanceState` 中手写开关的键。 */
        private const val STATE_INK_ENABLED = "state_ink_enabled"

        /** 构造进入阅读器的 Intent。[uid] 非空时写入 [EXTRA_UID]。 */
        fun intent(context: Context, uri: Uri, uid: String? = null): Intent =
            Intent(context, PdfReaderActivity::class.java)
                .putExtra(EXTRA_URI, uri)
                .apply { if (uid != null) putExtra(EXTRA_UID, uid) }
    }
}
