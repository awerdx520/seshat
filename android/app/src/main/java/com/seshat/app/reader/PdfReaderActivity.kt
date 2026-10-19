package com.seshat.app.reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.text.InputType
import android.util.Log
import android.view.GestureDetector
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.SeekBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.doOnNextLayout
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.PagerSnapHelper
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.R
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.ReaderPageMode
import com.seshat.app.settings.SettingsActivity
import com.seshat.app.settings.SettingsStore
import com.seshat.app.sync.PdfLocalSyncStore
import com.seshat.app.sync.PdfSyncMapper
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.RestClientSyncAdapter
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SyncManager
import com.seshat.app.sync.createReaderSync
import java.io.File
import java.io.IOException
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * PDF 阅读器（M3.3 MVP / M9.2 支持竖向连续滚动）。
 *
 * 渲染方案：使用 Android 系统内置的 [PdfRenderer]（API 21+，无需第三方 JNI 库），
 * 逐页渲染为 Bitmap，交由 [PdfPageAdapter] 在 [RecyclerView] 中显示。
 * 界面与 EPUB 侧同构（M10.8）：**顶部工具栏浮层**（返回 / 文件名 / 手写 / 批注 / 目录 / 设置）
 * + **底部进度浮层**（[SeekBar] + [TextView] 显示「当前页 / 总页数」，B2d：进度条拖动松手跳页、
 * 页码可点输入跳页），两块都是 overlay，不占布局。
 * 阅读区（[RecyclerView]）的**上下** padding 都随对应浮层的**可见性**与实时高度联动
 * （可见时预留浮层高度、隐藏时归零）且 `clipToPadding = false`（B2e），故页尾/页首内容
 * 不会被叠加的浮层遮挡，沉浸阅读时也不会在两端留下空白。
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

    /**
     * 主线程 `Handler`：仅用于 tap 回调的 `post` 与撤销。
     *
     * 不用 `recycler.post` 的原因：`View` 只有 `removeCallbacks(runnable)`，无法一次性撤销全部
     * 挂起回调；这里与 EPUB 侧（`EpubReaderActivity.tapHandler`）保持同一策略，
     * [onDestroy] 里 `removeCallbacksAndMessages(null)` 即可清空，避免已销毁的 Activity 被唤醒。
     */
    private val tapHandler = Handler(Looper.getMainLooper())

    /**
     * 已排入 [tapHandler]、尚未执行的单击（收到双击 / 长按时撤销）。
     *
     * 单击必须延迟派发：`GestureDetector` 对双击的**第一击**同样会回调 `onSingleTapUp`，
     * 立即执行会「先翻页再进入手写模式」。延迟窗口取系统双击超时
     * （`ViewConfiguration.getDoubleTapTimeout()`）。
     */
    private var pendingTap: Runnable? = null

    /** 页码进度条（B2d）：拖动松手才跳页，程序化同步由 [isSyncingSeekBar] 加闸。 */
    private lateinit var pageSeekBar: SeekBar

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
     * 目录解析专用单线程（`file://` 与 `content://` 两条路径共用）。
     *
     * 与 [syncExecutor] 隔离：outline 解析是阻塞 + 高内存操作，挤占同步线程会让一次目录解析
     * 阻塞进度推送；也不复用渲染线程，避免大 PDF 解析期间翻页卡顿。故独立成一个单线程池。
     */
    private val ioExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    /** 目录加载中标记：避免连点目录按钮并发起多次解析。 */
    private var tocLoading: Boolean = false

    /**
     * 本次打开的 PDF Uri（[onCreate] 里从 Intent 解出后留存）。
     *
     * `onCreate` 中的 `uri` 是局部变量，而目录解析发生在它的后台回调里，故必须提升为字段。
     */
    private var pdfUri: Uri? = null

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

    /**
     * 程序化写 `pageSeekBar.progress` 期间为 `true`：拦截由此产生的回调，防「跳页 → 滚动上报 →
     * 同步进度条 → 再跳页」的回环（第一道闸，见 [setupSeekBar] 的说明）。
     */
    private var isSyncingSeekBar: Boolean = false

    /** 用户手指正按在进度条上：此期间不覆盖其位置（否则拖动被滚动上报拉回）。 */
    private var isTrackingSeekBar: Boolean = false

    private lateinit var progressStore: PdfProgressStore
    private lateinit var annotationStore: PdfAnnotationStore
    private lateinit var inkStore: PdfInkStore

    /** 顶部工具栏浮层（返回/文件名/手写/批注/目录/设置）：与 [bottomChrome] 同步显隐。 */
    private lateinit var topChrome: View

    /** 底部进度浮层（页 SeekBar + 页码）：与 [topChrome] 同步显隐。 */
    private lateinit var bottomChrome: View

    /** 顶部浮层的文件名（PDF 没有书名元数据时显示文件名）。 */
    private lateinit var topTitleView: TextView

    // 浮层上的按钮都是 TextView（本项目无 ViewBinding，按钮外观由布局的 background/文字属性承担）。
    private lateinit var inkToggleButton: TextView
    private lateinit var inkUndoButton: TextView
    private lateinit var inkClearButton: TextView

    /** 手写模式开关（旋转经 savedInstanceState 恢复）。 */
    private var inkEnabled: Boolean = false

    /** 当前笔颜色（面板选色，不跨文档记忆——见 tech-debt）。 */
    private var inkColor: Int = InkOverlayView.DEFAULT_COLOR

    /** 当前笔归一化线宽。 */
    private var inkWidth: Float = InkOverlayView.DEFAULT_WIDTH_NORMALIZED

    /** 当前笔型。 */
    private var inkStyle: InkStyle = InkStyle.PEN

    /** 手写参数面板（仅手写模式显示）。 */
    private lateinit var inkPanel: View

    /**
     * 已写入阅读区的**顶部** padding（像素）；-1 表示尚未写入，见 [applyContentPadding]。
     *
     * 与 [appliedBottomPadding] 一起充当幂等闸：两者都没变就不重设 padding。
     */
    private var appliedTopPadding: Int = -1

    /** 已写入阅读区的**底部** padding（像素）；-1 表示尚未写入，见 [applyContentPadding]。 */
    private var appliedBottomPadding: Int = -1

    /** 浮层布局监听（同一实例挂到两块浮层上，只创建一次，见 [applyChromePaddingOnFirstLayout]）。 */
    private var chromeLayoutListener: View.OnLayoutChangeListener? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pdf_reader)

        // 先绑定视图，保证后续任何提前 finish 时 onDestroy 访问安全。
        recycler = findViewById(R.id.pdfPager)
        pageIndicator = findViewById(R.id.pdfPageIndicator)
        pageSeekBar = findViewById(R.id.pdfPageSeekBar)
        topChrome = findViewById(R.id.pdfTopChrome)
        bottomChrome = findViewById(R.id.pdfBottomChrome)
        topTitleView = findViewById(R.id.pdfTopTitle)
        inkToggleButton = findViewById(R.id.pdfInkToggleButton)
        inkUndoButton = findViewById(R.id.pdfInkUndoButton)
        inkClearButton = findViewById(R.id.pdfInkClearButton)
        // 手写参数面板：必须先于 updateInkChrome() 初始化（该方法会按手写模式切它的显隐）。
        inkPanel = findViewById(R.id.inkPanel)
        setupInkPanel()

        // 底部浮层贴底：按系统导航栏补底部 padding，避免控件被遮挡
        ViewCompat.setOnApplyWindowInsetsListener(bottomChrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                view.paddingLeft,
                view.paddingTop,
                view.paddingRight,
                bars.bottom + (INITIAL_CHROME_PADDING_DP * resources.displayMetrics.density).toInt(),
            )
            // 系统栏变化会改浮层高度（见上方 insets 说明）：同步一次阅读区 padding，
            // 否则页尾仍会按旧高度被遮挡（B2e）。
            view.post { applyContentPadding() }
            insets
        }
        // 顶部浮层同理：状态栏/刘海变化会改它的高度
        ViewCompat.setOnApplyWindowInsetsListener(topChrome) { view, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            view.setPadding(
                view.paddingLeft,
                bars.top + (INITIAL_CHROME_PADDING_DP * resources.displayMetrics.density).toInt(),
                view.paddingRight,
                view.paddingBottom,
            )
            view.post { applyContentPadding() }
            insets
        }

        // 阅读区上下 padding 自适应两块浮层的可见性与高度（B2e）：浮层叠在 RecyclerView 之上，
        // 不预留 padding 时页首/页尾内容会被压住。
        applyChromePaddingOnFirstLayout()

        // 手写开关跨旋转恢复：否则转屏后手写层会静默关闭。
        inkEnabled = savedInstanceState?.getBoolean(STATE_INK_ENABLED) ?: false

        val uri = extractUri()
        if (uri == null) {
            toast(getString(R.string.pdf_error_no_uri))
            finish()
            return
        }
        // 目录解析在后台线程的回调里还要读它，局部变量出不了 onCreate，故留存为字段。
        pdfUri = uri
        // 键选择的唯一落点：有服务端 uid 用 uid，否则用 uri 字符串（M7 之前的行为）
        uid = intent.getStringExtra(EXTRA_UID)?.trim()?.takeIf { it.isNotEmpty() }
        docId = uid ?: uri.toString()
        // 顶部工具栏显示文件名（PDF 无书名元数据，取 URI 末段；取不到就留空）
        topTitleView.text = uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() } ?: ""

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

        findViewById<TextView>(R.id.annotateButton).setOnClickListener { promptAnnotation() }
        findViewById<TextView>(R.id.backButton).setOnClickListener { finish() }
        findViewById<TextView>(R.id.tocButton).setOnClickListener { showPdfToc() }
        findViewById<TextView>(R.id.settingsButton).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        inkToggleButton.setOnClickListener { toggleInk() }
        inkUndoButton.setOnClickListener { undoInk() }
        inkClearButton.setOnClickListener { clearInk() }
        // 页码可点：输入页号直接跳页（B2d），与 EPUB 侧「点标题跳章」同一套交互。
        pageIndicator.setOnClickListener { showJumpToPageDialog() }
        setupSeekBar()

        // PdfBox-Android 需要一次性初始化资源加载器（字体/资源），只调一次即可；
        // 必须早于任何 PDDocument 使用（目录解析在第一次点「目录」时才发生）。
        com.tom_roush.pdfbox.android.PDFBoxResourceLoader.init(applicationContext)

        val pdf = openRenderer(uri)
        if (pdf == null) {
            toast(getString(R.string.pdf_error_open))
            finish()
            return
        }
        renderer = pdf
        lastPage = (pdf.pageCount - 1).coerceAtLeast(0)
        // 进度条上限 = 最大页索引；单页 PDF 无处可跳，禁用后视觉上不诱导拖动。
        pageSeekBar.max = lastPage
        pageSeekBar.isEnabled = lastPage > 0

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
        // 目录解析线程：只 shutdown（已入队的解析任务跑完即退出）。不中断，避免解析中途
        // 抛出难以处理的异常；其结果回调会因 isFinishing/isDestroyed 被丢弃。
        ioExecutor.shutdown()
        // 撤销尚未执行的延迟单击（下面若 recycler 未初始化，tapHandler 那条清理路径跑不到）
        cancelPendingTap()
        super.onDestroy()

        // 先解绑，避免销毁过程中仍有新的绑定提交渲染任务。
        if (::recycler.isInitialized) {
            // 撤销挂起的 tap 回调（onSingleTapUp 经 tapHandler.post 排入），
            // 避免已销毁的 Activity 被回调唤醒
            tapHandler.removeCallbacksAndMessages(null)
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
        // 页码文本是「当前页变化」的唯一汇聚点（滚动上报 / 恢复进度 / 跳页），
        // 故进度条同步只挂在这一处，三种路径共用一条。
        syncSeekBar(position)
    }

    /**
     * 装配页码进度条的监听（B2d）。
     *
     * **只在松手时跳页**：`onProgressChanged` 恒不动作（不滚动、不改页码）——拖过 300 页会连续
     * 触发上百次 `scrollToPosition`，每次都是一次整页布局，只有最后一次有意义；且若在其中回写
     * 页码文本，会与「滚动上报 → [syncSeekBar]」形成回环。
     */
    private fun setupSeekBar() {
        pageSeekBar.max = 0
        pageSeekBar.progress = 0
        pageSeekBar.isEnabled = false
        pageSeekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
            override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                // 恒不动作：拖动中不跳页；程序化 setProgress（fromUser = false）也在此被忽略，
                // 这是防回环的第一道闸（第二道是 [isSyncingSeekBar]，见 onStopTrackingTouch）。
            }

            override fun onStartTrackingTouch(seekBar: SeekBar?) {
                isTrackingSeekBar = true
            }

            override fun onStopTrackingTouch(seekBar: SeekBar?) {
                isTrackingSeekBar = false
                // 防回环：程序化 setProgress 不产生 tracking，本不会走到这里；
                // 仍用闸门兜住「同步期间被外部拖动」的极端时序。
                if (isSyncingSeekBar) return
                jumpToPage(ChapterSeekMath.indexOf(seekBar?.progress ?: 0, lastPage + 1))
            }
        })
    }

    /**
     * 把当前页同步到进度条（程序化写入，**不得**触发跳页）。
     *
     * 回环防护用布尔闸门 [isSyncingSeekBar] 而非 `SeekBar.isPressed`：`setProgress` 只触发
     * `onProgressChanged(fromUser = false)`，但「跳页 → 滚动 → [updateCurrentPage] →
     * [updateIndicator] → [syncSeekBar]」是同一调用栈内的同步链，闸门把这个窗口显式圈出来。
     * 拖动期间（[isTrackingSeekBar]）不覆盖用户手指的位置。
     *
     * 夹紧复用 [ChapterSeekMath.progressOf]（与章数同构，`count = lastPage + 1`），
     * 等价于任务要求的手写 `position.coerceIn(0, max)`。
     */
    private fun syncSeekBar(position: Int) {
        if (!::pageSeekBar.isInitialized) return
        isSyncingSeekBar = true
        try {
            pageSeekBar.max = lastPage
            if (!isTrackingSeekBar) {
                pageSeekBar.progress = ChapterSeekMath.progressOf(position, lastPage + 1)
            }
        } finally {
            isSyncingSeekBar = false
        }
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

    /**
     * 点击页码 → 输入页号跳页（B2d，与 EPUB 侧「点标题跳章」同一套写法）。
     *
     * 输入为 **1-based** 页号；换算与夹紧全部交给 [ChapterSeekMath.indexFromUserInput]
     * （纯逻辑、已有单测）：`count` 取 `lastPage + 1`（总页数，因 [lastPage] 是最大页索引），
     * 与 EPUB 传「章数」语义一致——超出上限夹紧到最后一页。非法输入（空白/非数字/≤0）
     * 只提示不跳转，弹窗保持已关闭。
     */
    private fun showJumpToPageDialog() {
        val pageCount = lastPage + 1
        val input = EditText(this).apply {
            inputType = InputType.TYPE_CLASS_NUMBER
            hint = getString(R.string.pdf_jump_page_hint, pageCount)
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
            .setTitle(R.string.pdf_jump_to_page)
            .setView(container)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val target = ChapterSeekMath.indexFromUserInput(input.text.toString(), pageCount)
                if (target == null) {
                    toast(getString(R.string.pdf_jump_invalid))
                } else {
                    jumpToPage(target)
                }
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

    /**
     * 切换手写模式。
     *
     * 进入/退出有两条路径（M10.8）：顶栏「手写」按钮（本方法）、阅读区**双击**（见 [installTapPaging]）；
     * 手写模式下长按不弹菜单（落笔优先）。
     *
     * 开启后落笔优先占用点击与滑动（见 [installTapPaging]），故此时翻页改由底部进度条
     * 与「点页码输入页号」承担——原「手写时显示翻页按钮」的做法随工具栏改版取消（M10.8）。
     */
    private fun toggleInk() {
        inkEnabled = !inkEnabled
        adapter?.setInkEnabled(inkEnabled)
        adapter?.setInkColor(inkColor)
        adapter?.setInkWidth(inkWidth)
        adapter?.setInkStyle(inkStyle)
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
        inkPanel.visibility = if (inkEnabled) View.VISIBLE else View.GONE
        // 面板显隐会改变顶部浮层高度 → 重新算阅读区 padding（否则顶部正文被面板压住）
        applyContentPadding()
    }

    /** 手写参数面板的点击接线（颜色 / 粗细 / 笔型），选中的控件用 alpha 区分。 */
    private fun setupInkPanel() {
        val colors = mapOf(
            R.id.inkColorRed to 0xFFE53935.toInt(),
            R.id.inkColorBlue to 0xFF1E88E5.toInt(),
            R.id.inkColorGreen to 0xFF43A047.toInt(),
            R.id.inkColorBlack to 0xFF212121.toInt(),
            R.id.inkColorOrange to 0xFFFB8C00.toInt(),
            R.id.inkColorPurple to 0xFF8E24AA.toInt(),
        )
        colors.forEach { (id, color) ->
            findViewById<View>(id).setOnClickListener {
                inkColor = color
                adapter?.setInkColor(color)
                refreshInkPanelSelection()
            }
        }
        val widths = mapOf(
            R.id.inkWidthThin to 0.0025f,
            R.id.inkWidthMedium to 0.004f,
            R.id.inkWidthThick to 0.007f,
        )
        widths.forEach { (id, width) ->
            findViewById<View>(id).setOnClickListener {
                inkWidth = width
                adapter?.setInkWidth(width)
                refreshInkPanelSelection()
            }
        }
        val styles = mapOf(
            R.id.inkStylePen to InkStyle.PEN,
            R.id.inkStyleMarker to InkStyle.MARKER,
            R.id.inkStyleHighlighter to InkStyle.HIGHLIGHTER,
        )
        styles.forEach { (id, style) ->
            findViewById<View>(id).setOnClickListener {
                inkStyle = style
                adapter?.setInkStyle(style)
                refreshInkPanelSelection()
            }
        }
        refreshInkPanelSelection()
    }

    /** 刷新面板选中态：选中的不透明、未选中的半透明（比自绘边框省事且不依赖 drawable）。 */
    private fun refreshInkPanelSelection() {
        if (!::inkPanel.isInitialized) return
        val selected = buildSet {
            add(
                when (inkColor) {
                    0xFF1E88E5.toInt() -> R.id.inkColorBlue
                    0xFF43A047.toInt() -> R.id.inkColorGreen
                    0xFF212121.toInt() -> R.id.inkColorBlack
                    0xFFFB8C00.toInt() -> R.id.inkColorOrange
                    0xFF8E24AA.toInt() -> R.id.inkColorPurple
                    else -> R.id.inkColorRed
                },
            )
            add(
                when {
                    inkWidth <= 0.003f -> R.id.inkWidthThin
                    inkWidth >= 0.006f -> R.id.inkWidthThick
                    else -> R.id.inkWidthMedium
                },
            )
            add(
                when (inkStyle) {
                    InkStyle.PEN -> R.id.inkStylePen
                    InkStyle.MARKER -> R.id.inkStyleMarker
                    InkStyle.HIGHLIGHTER -> R.id.inkStyleHighlighter
                },
            )
        }
        val all = listOf(
            R.id.inkColorRed, R.id.inkColorBlue, R.id.inkColorGreen, R.id.inkColorBlack,
            R.id.inkColorOrange, R.id.inkColorPurple,
            R.id.inkWidthThin, R.id.inkWidthMedium, R.id.inkWidthThick,
            R.id.inkStylePen, R.id.inkStyleMarker, R.id.inkStyleHighlighter,
        )
        all.forEach { id ->
            findViewById<View>(id).alpha = if (id in selected) 1f else 0.35f
        }
    }

    // ---- 点击翻页 ----

    /**
     * 安装点击翻页：OnItemTouchListener + GestureDetector。
     *
     * 关键：onInterceptTouchEvent **恒返回 false**，只把事件喂给 GestureDetector，
     * 绝不拦截——否则会吞掉滑动与 PagerSnapHelper 的吸附。
     *
     * 三手势分工（M10.8）：
     * - 单击 → [scheduleTap] 延迟派发 [handleTap]（延迟是为了让双击的第一击可被撤销）；
     * - 双击 → [toggleInk] 进入/退出手写模式；
     * - 长按 → [showLongPressMenu]（复制本页文字 / 高亮标注 / 进入手写）；
     * 手写模式下三者都让位给落笔。
     */
    private fun installTapPaging() {
        val detector = GestureDetector(this, object : GestureDetector.SimpleOnGestureListener() {
            override fun onSingleTapUp(e: MotionEvent): Boolean {
                if (inkEnabled) return false // 落笔优先：手写模式下单击不翻页、不切工具栏
                // 坐标先取值：事件对象在 post 之后可能已被系统复用。
                val tapX = e.x
                // 延迟派发：双击的第一击也会回调 onSingleTapUp，立即执行会「先翻页再进手写」
                scheduleTap(tapX)
                return true
            }

            override fun onDoubleTap(e: MotionEvent): Boolean {
                // 双击进入/退出手写模式（手写模式下双击退出）——先撤销第一击排下的翻页
                cancelPendingTap()
                toggleInk()
                return true
            }

            override fun onLongPress(e: MotionEvent) {
                if (inkEnabled) return // 手写模式下长按是落笔的一部分，不弹菜单
                cancelPendingTap()
                showLongPressMenu()
            }
        })
        recycler.addOnItemTouchListener(object : RecyclerView.SimpleOnItemTouchListener() {
            override fun onInterceptTouchEvent(rv: RecyclerView, e: MotionEvent): Boolean {
                detector.onTouchEvent(e)
                return false
            }
        })
    }

    /** 排入一次延迟单击（窗口 = 系统双击超时；期间收到双击/长按即撤销）。 */
    private fun scheduleTap(tapX: Float) {
        cancelPendingTap()
        val runnable = Runnable {
            pendingTap = null
            handleTap(tapX)
        }
        pendingTap = runnable
        // 必须 ≥ 系统双击超时：否则 250–300ms 的「慢双击」会先触发翻页再进手写。
        // 用系统值而不是硬编码常量，跨设备（不同 ViewConfiguration）都安全。
        tapHandler.postDelayed(runnable, ViewConfiguration.getDoubleTapTimeout().toLong())
    }

    /** 撤销尚未执行的单击（双击 / 长按 / 销毁时调用）。 */
    private fun cancelPendingTap() {
        pendingTap?.let { tapHandler.removeCallbacks(it) }
        pendingTap = null
    }

    /**
     * 长按菜单（M10.8）：复制本页文字 / 高亮标注 / 进入手写。
     *
     * PDF 用 `PdfRenderer` 逐页渲染成位图，**没有文本选择层**，所以「复制」不能像 EPUB 那样
     * 复制选中文本，改为用 PdfBox 提取当前页文本（扫描版 PDF 没有文本层 → 提示无文字）。
     */
    private fun showLongPressMenu() {
        val items = arrayOf(
            getString(R.string.pdf_menu_copy_text),
            getString(R.string.pdf_menu_highlight),
            getString(R.string.pdf_menu_handwrite),
        )
        AlertDialog.Builder(this)
            .setItems(items) { _, which ->
                when (which) {
                    0 -> copyCurrentPageText()
                    1 -> promptAnnotation()
                    2 -> toggleInk()
                }
            }
            .show()
    }

    /** 后台提取当前页文本并写入剪贴板；无文本层 / 失败时提示。 */
    private fun copyCurrentPageText() {
        val uri = pdfUri
        if (uri == null) {
            toast(getString(R.string.pdf_copy_no_text))
            return
        }
        val page = firstVisiblePage()
        ioExecutor.execute {
            // sizeHint 也要在后台读：openAssetFileDescriptor 是 binder 调用，主线程做不合适
            val sizeHint = runCatching {
                contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
            }.getOrNull() ?: -1L
            // 解析是阻塞 + 高内存操作，必须离开主线程（与目录解析同样的理由）。
            // sizeHint 同样不可信（provider 自报），流本身再套一层硬上限。
            val text = runCatching {
                contentResolver.openInputStream(uri)?.use { raw ->
                    PdfTextExtractor.extractPage(
                        BoundedInputStream(raw, PdfTextExtractor.MAX_BYTES), page, sizeHint,
                    )
                }
            }.getOrNull().orEmpty()
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                if (text.isBlank()) {
                    toast(getString(R.string.pdf_copy_no_text))
                    return@runOnUiThread
                }
                // 整页文本可能数 MB，超 binder 事务上限会抛 TransactionTooLargeException → 截断
                val clipped = if (text.length > MAX_CLIP_CHARS) {
                    text.substring(0, MAX_CLIP_CHARS)
                } else {
                    text
                }
                val clipboard = getSystemService(ClipboardManager::class.java)
                clipboard?.setPrimaryClip(
                    ClipData.newPlainText(getString(R.string.pdf_copy_label), clipped),
                )
                toast(
                    getString(
                        if (clipped.length < text.length) {
                            R.string.pdf_copy_truncated
                        } else {
                            R.string.pdf_copy_done
                        },
                    ),
                )
            }
        }
    }

    /**
     * 处理单击：按 [TapZone] 三段分区翻屏或切换工具栏。
     *
     * 横向翻一页（复用 [movePage]），竖向滚动一屏（滚动量取可视高度，浮层 padding 已排除）。
     */
    private fun handleTap(tapX: Float) {
        val width = recycler.width
        if (width <= 0) {
            toggleChrome()
            return
        }
        when (TapZone.zone(tapX / width)) {
            TapZone.Zone.PREV -> moveOneScreen(-1)
            TapZone.Zone.NEXT -> moveOneScreen(1)
            TapZone.Zone.TOGGLE -> toggleChrome()
        }
    }

    /** 翻一屏：横向翻一页，竖向滚动一屏（滚动量为扣除浮层 padding 后的可视高度）。 */
    private fun moveOneScreen(delta: Int) {
        if (pageMode == ReaderPageMode.HORIZONTAL) {
            movePage(delta)
            return
        }
        val viewport = (recycler.height - recycler.paddingTop - recycler.paddingBottom)
            .coerceAtLeast(1)
        recycler.smoothScrollBy(0, delta * viewport)
    }

    /** 翻页：横向用 scrollToPosition（立即跳转，避免与 PagerSnapHelper 的动画竞争）。 */
    private fun movePage(delta: Int) {
        val current = firstVisiblePage()
        val target = (current + delta).coerceIn(0, lastPage)
        if (target == current) return
        recycler.scrollToPosition(target)
    }

    /**
     * 跳转到指定页（0-based 绝对定位，供进度条松手与页码输入复用）。
     *
     * 滚动方式与 [movePage] 一致（`scrollToPosition`，立即跳转、不与 PagerSnapHelper 动画竞争）；
     * 越界夹紧到 `[0, lastPage]`，已在该页时直接返回（页码文本与进度条本已就位）。
     *
     * **补一次 [updateCurrentPage]**：`scrollToPosition` 是**布局型**跳转，RecyclerView 只在
     * 可见子项范围变化时补发 `onScrolled(0, 0)`；竖向连续滚动下跳页可能不改变可见范围，
     * 指示器与进度条就会停在旧值。与 EPUB 侧跳章同样用「下一次布局后主动走既有链路」兜住。
     */
    private fun jumpToPage(index: Int) {
        val target = index.coerceIn(0, lastPage)
        if (target == firstVisiblePage()) return
        recycler.scrollToPosition(target)
        recycler.doOnNextLayout { updateCurrentPage() }
    }

    /**
     * 把浮层实时高度写入阅读区（`pdfPager`）的上下 padding（B2e / M10.8）。
     *
     * **为什么要用运行时高度**：浮层高度不是固定值——按钮文案换行、系统字体缩放、
     * 系统栏（状态栏/导航栏/刘海）通过 [WindowInsetsCompat] 追加的 padding 都会改变它。
     * 硬编码常量在字号放大或三键导航下必然失准，仍会遮住页首/页尾。
     *
     * **为什么监听浮层布局而不是只在 `onCreate` 里读一次**：`onCreate` 阶段视图尚未测量，
     * `height` 恒为 0。监听首次布局后并用 `post` 挪到本轮布局遍历结束再读，才能拿到真实高度。
     *
     * **为什么两块浮层都挂监听**：两块各自可能因内容（文件名行、insets）单独改变高度，
     * 挂在同一块上会漏掉另一块的独立变化。同一个 listener 实例挂两次，[chromeLayoutListener]
     * 记录该实例是否已挂过，重复调用不会重复注册。
     *
     * **为什么监听常驻而不移除**：本页的浮层高度还会被 insets 回调改动（切三键/手势导航、旋转屏），
     * 且 [toggleChrome] 要求 padding 随可见性联动回收（浮层是 overlay，隐藏后阅读区应铺满）——
     * 若只写一次，系统栏变高后页首/页尾会重新被遮挡、隐藏浮层后又会在两端留白。
     * 监听常驻，靠 [appliedTopPadding]/[appliedBottomPadding] 做「值未变则不写」的幂等闸：
     * 只有真的变了才重设 padding，避免常规滚动/键盘等布局反复写 padding 打断滚动锚点。
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
                // post：等本轮布局遍历结束（浮层高度稳定）后再读
                v.post { applyContentPadding() }
            }
        }
        chromeLayoutListener = listener
        topChrome.addOnLayoutChangeListener(listener)
        bottomChrome.addOnLayoutChangeListener(listener)
    }

    /**
     * 按两块浮层当前**可见性**与**高度**写入阅读区上下 padding。
     *
     * 某块浮层隐藏时对应方向 padding 必须归零（浮层是 overlay，不占布局，否则会留一条等高空白）；
     * 可见但高度仍为 0（尚未测量）时直接 `return`，等下一次布局回调；上下都算出的值与上次相同
     * 则跳过（幂等闸），避免常规滚动反复写 padding 打断滚动锚点。
     */
    private fun applyContentPadding() {
        if (!::recycler.isInitialized) return
        if (!::topChrome.isInitialized || !::bottomChrome.isInitialized) return
        val topVisible = topChrome.visibility == View.VISIBLE
        val bottomVisible = bottomChrome.visibility == View.VISIBLE
        val topHeight = topChrome.height
        val bottomHeight = bottomChrome.height
        // 浮层可见但尚未测量：等下一次布局回调
        if (topVisible && topHeight <= 0) return
        if (bottomVisible && bottomHeight <= 0) return
        val padding = ReaderChrome.padding(topVisible, bottomVisible, topHeight, bottomHeight)
        if (padding.top == appliedTopPadding && padding.bottom == appliedBottomPadding) return
        appliedTopPadding = padding.top
        appliedBottomPadding = padding.bottom
        recycler.setPadding(0, padding.top, 0, padding.bottom)
        // 必须开：否则内容被裁在 padding 内，而不是延伸到半透明浮层下方
        recycler.clipToPadding = false
    }

    /** 切换两块浮层工具栏的显隐（沉浸阅读 / 恢复）。 */
    private fun toggleChrome() {
        val target = if (topChrome.visibility == View.VISIBLE) View.GONE else View.VISIBLE
        topChrome.visibility = target
        bottomChrome.visibility = target
        // 关键：padding 必须随可见性联动（浮层是 overlay，隐藏后阅读区应铺满）
        applyContentPadding()
        // GONE → VISIBLE 的那一刻 height 仍是 0，applyContentPadding 会提前返回（等测量），
        // 故再投递一次，在本轮布局结束后按真实高度补写（否则显示浮层后 padding 停在 0，
        // 正文前几行被顶栏压住）。
        bottomChrome.post { applyContentPadding() }
    }

    /**
     * 显示 PDF 目录对话框（M10.8 / A-T6）。
     *
     * PDF 没有 EPUB 那种现成章节表，目录来自书签树（[PdfOutlineReader]，PdfBox 解析）。
     * 解析是阻塞 + 高内存操作，必须放在 [ioExecutor] 后台线程；失败/无 outline 时由
     * [PdfTocEntries.build] 回退「第 N 页」页码目录（此时对话框永不空手）。
     * 点击条目用 [jumpToPage] 跳转（与进度条拖动、页码输入同一条路径）。
     *
     * 并发防抖：解析期间 [tocLoading] 为 `true`，连点按钮不会叠加多份解析。
     */
    private fun showPdfToc() {
        if (tocLoading) return
        val uri = pdfUri
        if (uri == null) {
            toast(getString(R.string.reader_toc_empty))
            return
        }
        tocLoading = true
        // 总页数取 lastPage + 1（lastPage 是最大页索引，至少为 0，故单页文档也是 1 页）
        val pageCount = lastPage + 1
        ioExecutor.execute {
            val outline = runCatching { readOutline(uri) }.getOrDefault(emptyList())
            val entries = PdfTocEntries.build(outline, pageCount)
            runOnUiThread {
                tocLoading = false
                // 解析期间可能已退出：回调必须自我作废，否则会对已销毁的 Activity 弹框
                if (isFinishing || isDestroyed) return@runOnUiThread
                showTocDialog(entries)
            }
        }
    }

    /**
     * 按 URI scheme 读 outline：`file` 直接给 [File]，其余走 `contentResolver` 流（带大小预检）。
     *
     * 只在 [ioExecutor] 线程调用（阻塞 + 高内存）。异常由调用方 `runCatching` 收敛：
     * 目录不是阅读必需功能，任何失败都退化为页码目录，不打扰用户。
     */
    private fun readOutline(uri: Uri): List<PdfOutlineReader.PdfOutlineItem> {
        if (uri.scheme == "file") {
            val path = uri.path ?: return emptyList()
            return PdfOutlineReader.read(File(path))
        }
        // content:// 拿不到 File：先用 AssetFileDescriptor 的 length 做大小预检（未知时 -1）
        val sizeHint = runCatching {
            contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length }
        }.getOrNull() ?: -1L
        // sizeHint 是 provider 自报值（可谎报 0/-1 绕过预检），故流本身再套一层硬上限
        return contentResolver.openInputStream(uri)?.use { raw ->
            PdfOutlineReader.read(BoundedInputStream(raw, PdfOutlineReader.MAX_OUTLINE_BYTES), sizeHint)
        } ?: emptyList()
    }

    /** 弹出目录单选对话框；空表提示「本书没有目录」（正常路径不会为空，仅兜底）。 */
    private fun showTocDialog(entries: List<PdfTocEntries.Entry>) {
        if (entries.isEmpty()) {
            toast(getString(R.string.reader_toc_empty))
            return
        }
        val labels = entries.map { entry ->
            // 用全角空格做缩进（TextView 单行无层级样式，缩进最直观）
            "　".repeat(entry.depth) + entry.title
        }.toTypedArray()
        // 高亮当前页对应项（-1 表示空表，此处已提前返回，故必为合法索引）
        val checked = PdfTocEntries.indexForPage(entries, firstVisiblePage())
        AlertDialog.Builder(this)
            .setTitle(R.string.reader_toc)
            .setSingleChoiceItems(labels, checked) { dialog, which ->
                val target = entries[which].pageIndex
                // pageIndex < 0：该书签没有页目标（纯 URI 链接），只关闭对话框，不跳页
                if (target >= 0) jumpToPage(target)
                dialog.dismiss()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
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

        /**
         * 浮层垂直内边距基线（dp）：与布局 `activity_pdf_reader.xml` 的 `paddingVertical` 对应，
         * insets 回调里在系统栏 inset 之上叠加这一份，避免内容紧贴系统栏。
         */
        private const val INITIAL_CHROME_PADDING_DP = 6

        /**
         * 「复制本页文字」写入剪贴板的字符上限（10 万）。
         *
         * 恶意/异常 PDF 单页可含数 MB 文本，直接塞进 `ClipData` 会超过 binder 事务上限
         * （约 1 MB）抛 `TransactionTooLargeException` 而崩溃；截断远优于崩溃。
         */
        private const val MAX_CLIP_CHARS = 100_000

        /** `savedInstanceState` 中手写开关的键。 */
        private const val STATE_INK_ENABLED = "state_ink_enabled"

        /** 构造进入阅读器的 Intent。[uid] 非空时写入 [EXTRA_UID]。 */
        fun intent(context: Context, uri: Uri, uid: String? = null): Intent =
            Intent(context, PdfReaderActivity::class.java)
                .putExtra(EXTRA_URI, uri)
                .apply { if (uid != null) putExtra(EXTRA_UID, uid) }
    }
}
