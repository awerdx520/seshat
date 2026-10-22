package com.seshat.app.reader

import android.content.ClipData
import android.content.ClipboardManager
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
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
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.ViewConfiguration
import android.view.ViewGroup
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.ImageView
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
import com.seshat.app.sync.ProgressPushResult
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.RestClientSyncAdapter
import com.seshat.app.sync.SecurePrefs
import com.seshat.app.sync.SyncManager
import com.seshat.app.sync.createReaderSync
import java.io.File
import java.io.IOException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import kotlin.math.roundToInt

/**
 * PDF 阅读器（M3.3 MVP / M9.2 支持竖向连续滚动）。
 *
 * 渲染方案：使用 Android 系统内置的 [PdfRenderer]（API 21+，无需第三方 JNI 库），
 * 逐页渲染为 Bitmap，交由 [PdfPageAdapter] 在 [RecyclerView] 中显示。
 * 界面与 EPUB 侧同构（M10.8）：**顶部工具栏浮层**（返回 / 文件名 / 手写 / 批注 / 目录 / 设置）
 * + **底部进度浮层**（[SeekBar] + [TextView] 显示「当前页 / 总页数」，B2d：进度条拖动松手跳页、
 * 页码可点输入跳页），两块都是 overlay，不占布局；**手写工具栏**是屏幕右侧 56dp 的单列图标条
 * （退出 / 颜色（主 3 色 + 更多可展开）/ 粗细 / 笔型 / 撤销 / 清空），仅手写模式显示，
 * 独立于顶部浮层。
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
 * - 笔迹     → [PdfInkStore]，键 `pdf_ink_<key>`（**渲染唯一真相**）。
 * 手写笔迹同时以 `kind=ink` 批注的形式进 [PdfAnnotationStore] 作为**同步镜像**（M10.3 T6，
 * 由 [InkAnnotationMapper] 生成 location），镜像不参与绘制。
 * - 书签     → [PdfBookmarkStore]，键 `pdf_bookmark_<key>`。
 * 四者共用 `SharedPreferences("pdf_reader")`，与 epub 侧键空间隔离；
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

    /**
     * 「进度冲突已提示过」标记（同一 Activity 生命周期内只提示一次）。
     *
     * 只在同步线程写入、只被 [notifyProgressConflict] 读取；`true` 之后不再弹提示，
     * 避免服务端持续冲突时每退出一次阅读器就打扰读者一次。
     */
    private var progressConflictNotified: Boolean = false

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

    /** 书签存储（M10.10）：与进度/批注/笔迹共用 pdf_reader prefs。 */
    private lateinit var bookmarkStore: PdfBookmarkStore

    /** 顶部工具栏浮层（返回/文件名/手写/批注/目录/设置）：与 [bottomChrome] 同步显隐。 */
    private lateinit var topChrome: View

    /** 底部进度浮层（页 SeekBar + 页码）：与 [topChrome] 同步显隐。 */
    private lateinit var bottomChrome: View

    /** 顶部浮层的文件名（PDF 没有书名元数据时显示文件名）。 */
    private lateinit var topTitleView: TextView

    /** 目录抽屉（M10.9）。 */
    private lateinit var tocDrawer: TocDrawer

    /**
     * 批注抽屉（M10.3 / T5）。
     *
     * 与 [tocDrawer] 挂在**同一个内容容器**上（本组件后创建 → 视图层级在上层），
     * 但两者互斥：打开任一方前先关另一方，避免「两个遮罩叠着、返回键不知关哪个」。
     */
    private lateinit var annotationDrawer: AnnotationDrawer

    /**
     * 待删批注队列（M10.3 T3）：与 EPUB 侧共用同一个队列文件（`reader_annotations`），
     * 键为 `pending_deletes_<uid>`，因此与 PDF 自己的批注数据键（`pdf_reader`）互不干扰。
     */
    private lateinit var pendingDeletes: PendingDeletes

    // 顶栏按钮仍是 TextView；手写工具栏（M10.10 改版）改为纯图标 ImageView，
    // 外观由布局的 background / src / padding 承担（本项目无 ViewBinding）。
    private lateinit var inkToggleButton: TextView
    private lateinit var inkUndoButton: ImageView
    private lateinit var inkClearButton: ImageView

    /** 顶栏书签按钮（M10.10）：图标随当前页是否有书签在实心/空心间切换。 */
    private lateinit var bookmarkButton: ImageView

    /** 右侧手写工具栏的「退出手写」按钮（等价于顶栏【手写】开关）。 */
    private lateinit var inkExitButton: ImageView

    /** 手写模式开关（旋转经 savedInstanceState 恢复）。 */
    private var inkEnabled: Boolean = false

    /** 当前笔颜色（面板选色，不跨文档记忆——见 tech-debt）。 */
    private var inkColor: Int = InkOverlayView.DEFAULT_COLOR

    /** 当前笔归一化线宽。 */
    private var inkWidth: Float = InkOverlayView.DEFAULT_WIDTH_NORMALIZED

    /** 当前笔型。 */
    private var inkStyle: InkStyle = InkStyle.PEN

    /** 右侧手写条是否展开「更多颜色」（会话内状态，不持久化；每次进入手写模式重置为折叠）。 */
    private var inkColorsExpanded: Boolean = false

    /**
     * 页索引（0-based）→ `(宽 pt, 高 pt)` 缓存，供手写镜像登记换算坐标（M10.3 T6）。
     *
     * 只在主线程读写（落笔回调与撤销/清空都在主线程），无需加锁；[PdfRenderer] 在同一
     * Activity 生命周期内不变，故缓存无失效问题。
     */
    private val pageSizesPt = mutableMapOf<Int, Pair<Double, Double>>()

    /** 手写工具栏（屏幕右侧竖排浮动条，仅手写模式显示）。 */
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

        // 目录抽屉（M10.9）：挂在内容容器最上层；点击可跳转行 → 跳页
        tocDrawer = TocDrawer(findViewById(android.R.id.content)) { index ->
            jumpToPage(index)
        }

        // 批注抽屉（M10.3 / T5）：必须在目录抽屉之后创建，两层遮罩才不会有层级歧义
        annotationDrawer = AnnotationDrawer(
            root = findViewById(android.R.id.content),
            onItemClick = { row -> jumpToAnnotation(row) },
            onItemEdit = { row -> editAnnotationRow(row) },
            onItemDelete = { row -> deleteAnnotationRow(row) },
        )

        // 先绑定视图，保证后续任何提前 finish 时 onDestroy 访问安全。
        recycler = findViewById(R.id.pdfPager)
        pageIndicator = findViewById(R.id.pdfPageIndicator)
        pageSeekBar = findViewById(R.id.pdfPageSeekBar)
        topChrome = findViewById(R.id.pdfTopChrome)
        bottomChrome = findViewById(R.id.pdfBottomChrome)
        topTitleView = findViewById(R.id.pdfTopTitle)
        bookmarkButton = findViewById(R.id.pdfBookmarkButton)
        inkToggleButton = findViewById(R.id.pdfInkToggleButton)
        inkUndoButton = findViewById(R.id.pdfInkUndoButton)
        inkClearButton = findViewById(R.id.pdfInkClearButton)
        // 手写工具栏（屏幕右侧竖排浮动条）：必须先于 updateInkChrome() 初始化
        // （该方法会按手写模式切它的显隐）。
        inkPanel = findViewById(R.id.inkPanel)
        inkPanel.background = GradientDrawable().apply {
            cornerRadius = 10 * resources.displayMetrics.density
            setColor(0xE6000000.toInt())
        }
        inkExitButton = findViewById(R.id.inkExitButton)
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

        // 进入阅读即沉浸：浮层默认隐藏，阅读区铺满；点屏幕中间才调出工具栏（用户 2026-10-20 要求）
        topChrome.visibility = View.GONE
        bottomChrome.visibility = View.GONE
        // 浮层 GONE → padding 应归零；此处显式算一次并补一次 post，防止此前已按可见浮层写入过非零值
        applyContentPadding()
        topChrome.post { applyContentPadding() }

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
        bookmarkStore = PdfBookmarkStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
            keys = { prefs.all.keys },
            remove = { key -> prefs.edit().remove(key).apply() },
        )
        // 旧键一次性清理（三个 store 共用 pdf_reader prefs，故共用一个标记）
        clearLegacyOnce()
        // 待删队列：队列键 uid 维度，与 PDF 的批注数据键（pdf_reader）互不干扰
        pendingDeletes = PendingDeletes(this)

        findViewById<TextView>(R.id.annotateButton).setOnClickListener { promptAnnotation() }
        findViewById<TextView>(R.id.backButton).setOnClickListener { finish() }
        findViewById<TextView>(R.id.tocButton).setOnClickListener { showPdfToc() }
        findViewById<TextView>(R.id.settingsButton).setOnClickListener {
            startActivity(Intent(this, SettingsActivity::class.java))
        }
        // 顶栏「列表」入口（打开批注抽屉）：代码插入，零新增 XML / 零新增 R.id.
        installAnnotationListButton()
        inkToggleButton.setOnClickListener { toggleInk() }
        bookmarkButton.setOnClickListener { toggleBookmark() }
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
        // 初始定位也要刷一次书签图标（updateCurrentPage 会因 lastReportedPage 已同步而提前返回）
        refreshBookmarkButton()

        // Store 与 docId 均就绪后再装配同步（内部三条守卫，任一不满足即完全跳过网络）。
        // 放在恢复进度之后：拉取只会写本地 Store，不会打断已完成的定位。
        setupSync()

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
     * **手写笔迹（[inkStore]）的同步方式**（M10.3 T6）：笔迹本身仍只存本地，同步的是
     * `kind=ink` 的**镜像批注**——落笔完成时登记一条，打开带 uid 的书时把「本地已有的历史笔迹」
     * 一次性补登（[backfillInkAnnotations]），服务端 `(uid, kind, location, text)` 幂等去重兜底。
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
            // 待删队列：离线删除的服务端 id 在这里持久化，flush 时补发 DELETE（M10.3 T3）
            pendingDeletes = pendingDeletes,
        ) ?: return
        syncManager = manager
        val executor = Executors.newSingleThreadExecutor().also { syncExecutor = it }
        executor.execute {
            runCatching {
                // 批注：合并（幂等，按 location + text 去重），远端新增写入本地
                manager.pullAnnotations(id)
                // 手写补登（T6）：**必须排在 pull 之后**——pull 会把服务端已有的 ink 批注落到本地，
                // 补登时按本地幂等键就能跳过它们，省掉 N 个「发了也白发」的 POST
                val backfilled = backfillInkAnnotations()
                // 进度：仅本地没有进度时拉取（避免覆盖本机正在读的页码）
                if (progressStore.load(id) == null) manager.pullProgress(id)
                // 本地已有进度：推送上去（服务端 updated_at 会因此前进）。
                // 用 detailed 版本：409 冲突重发仍失败的结局必须单独处置，否则会落进下面这条
                // 笼统的「拉取失败（已忽略）」，冲突再次被静默吞掉（计划 T3）。
                handleProgressPush(manager.pushProgressDetailed(id), position = null)
                // 补登出东西才推一次（否则每次打开都多一轮无意义的批注往返）
                if (backfilled > 0) manager.pushAnnotations(id)
            }.onFailure { Log.w(TAG, "拉取阅读状态失败（已忽略）", it) }
        }
    }

    /**
     * 把本地已有的手写笔迹一次性登记为 `kind=ink` 的待上传批注（M10.3 T6）。
     *
     * **幂等键在客户端先判**（[InkAnnotationMapper.pendingInkLocations]）：本地已有同
     * `(kind, location, text)` 的批注一律跳过，因此重复打开同一本书不会每次都发 N 个 POST；
     * 服务端 `(uid, kind, location, text)` 命中返回 200 是第二道兜底（本地被清空后再次补登）。
     *
     * **失败不影响阅读**：整段 `runCatching`，异常只记一条 warn 日志——补登是后台增强，
     * 不能让它把「打开书」这条主路径拖垮。
     *
     * 线程约定：在 [syncExecutor] 单线程上执行（[PdfInkStore] / [PdfAnnotationStore] 都是
     * SharedPreferences 读写；与同步线程同源，但**与主线程（读者落笔/删除批注）是并发写**，
     * 因此两个 store 的写方法各自用 `@Synchronized` 串行化 read-modify-write）。
     *
     * @return 本次新增的待上传条数（0 表示无需上传）
     */
    private fun backfillInkAnnotations(): Int = runCatching {
        if (!::inkStore.isInitialized || !::annotationStore.isInitialized) return@runCatching 0
        val pages = inkStore.document(docId).pages
        if (pages.isEmpty()) return@runCatching 0
        val pending = InkAnnotationMapper.pendingInkLocations(
            pages = pages,
            existing = annotationStore.list(docId),
            // 页尺寸仍需 openPage，故回到主线程读；读不到（渲染器已关）该页跳过
            pageSizePt = { page -> mainThreadPageSizePt(page) },
        )
        if (pending.isEmpty()) return@runCatching 0
        val now = System.currentTimeMillis()
        pending.forEach { location ->
            annotationStore.add(InkAnnotationMapper.inkAnnotation(docId, location, now))
        }
        Log.i(TAG, "手写补登：新增 ${pending.size} 条待上传批注")
        pending.size
    }.onFailure { Log.w(TAG, "手写补登失败（已忽略）", it) }.getOrDefault(0)

    /** 在同步线程上取页尺寸：`PdfRenderer` 只能在主线程之外的同一把锁里打开，故切回主线程取。 */
    private fun mainThreadPageSizePt(page: Int): Pair<Double, Double>? {
        if (Looper.myLooper() == Looper.getMainLooper()) return pageSizePt(page)
        val holder = arrayOfNulls<Pair<Double, Double>>(1)
        val latch = CountDownLatch(1)
        tapHandler.post {
            holder[0] = pageSizePt(page)
            latch.countDown()
        }
        // 有界等待：主线程正忙于渲染时宁可放弃该页补登，也不让同步线程无限阻塞
        latch.await(2, TimeUnit.SECONDS)
        return holder[0]
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
     * | `Pushed` | 服务端已保存本地值 | 成功，记住页码（防抖） |
     * | `Merged` | 409 后判定服务端较新，本地已被服务端值覆盖 | 成功（预期语义），不打扰读者 |
     * | `Rejected` | 409 后重发仍冲突，本地值**未上行** | warn 日志 + 一次性提示，**不得静默** |
     * | `Skipped` | 零请求（本地无进度 / uid 空白） | 什么都不做，也不记页码 |
     *
     * @param position 本次推送的页码串；仅「服务端已认可」（`Pushed` / `Merged`）时写入
     *   [lastPushedPosition]。`null` 表示调用方不在同步线程的防抖路径上（如打开文档时的首推）。
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
            toast(getString(R.string.reader_progress_conflict))
        }
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
        // 删除传播与「新增/修改」同源时机：离线删除的批注在这里补发 DELETE（M10.3 T3）
        enqueuePushDeletes()
        // 新增/修改的补推（M10.3 T6）：落笔时那次 push 可能因离线失败，手写镜像会一直停在
        // dirty 状态；补登产生的 ink 批注同样在这里兜底。pushAnnotations 内部先 list 一次、
        // 「未 dirty 且已有 serverId」的条目零请求跳过，故代价是一次 GET。
        enqueuePushAnnotations()
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
        // 顶栏书签图标跟随当前页：翻页后实心/空心要切换。
        refreshBookmarkButton()
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
     * 顶栏已有「添加批注」（`annotateButton`），故本按钮文案取「列表」以区分。
     * **视图由代码克隆同排「目录」按钮的可视属性后插入其左侧**：零新增 XML、零新增 `R.id.`，
     * 高度/padding/可点击涟漪与同排按钮完全一致，`pdfTopChrome` 的显隐与 insets 联动自动生效。
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

    /** store → 中性条目：抽屉与 [AnnotationGrouping] 只认 [AnnotationItem]，不碰本地模型。 */
    private fun annotationItems(): List<AnnotationItem> = annotationStore.list(docId).map { annotation ->
        AnnotationItem(
            id = "pdf:${annotation.id}",
            kind = annotation.kind,
            note = annotation.text,
            selectedText = annotation.selectedText,
            page = pageOf(annotation),
            pending = annotation.dirty,
        )
    }

    /** location → 页号（1-based）；`LocationCodec` 的三种 page 形态都能取，`Unknown` 返回 `null`。 */
    private fun pageOf(annotation: PdfAnnotation): Int? =
        when (val parsed = LocationCodec.parse(annotation.location)) {
            is LocationCodec.Parsed.Page -> parsed.page
            is LocationCodec.Parsed.PageRect -> parsed.page
            is LocationCodec.Parsed.PageInk -> parsed.page
            else -> null
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
        annotationDrawer.show(annotationItems(), currentPage = firstVisiblePage() + 1)
    }

    /** 数据变更后刷新已打开的抽屉（未打开时无操作，避免无谓构建视图）。 */
    private fun refreshAnnotationDrawer() {
        if (!::annotationDrawer.isInitialized || !annotationDrawer.isShowing) return
        annotationDrawer.show(annotationItems(), currentPage = firstVisiblePage() + 1)
    }

    /**
     * 行 → store 记录。
     *
     * ink 汇总行（[AnnotationGrouping.INK_SUMMARY_ID]）代表整组 N 笔，这里返回该组全部记录，
     * 调用方取第一条做定位（同组 ink 通常在同一页）。
     */
    private fun annotationsForRow(row: AnnotationRow): List<PdfAnnotation> {
        val all = annotationStore.list(docId)
        return if (row.id == AnnotationGrouping.INK_SUMMARY_ID) {
            all.filter { it.kind == AnnotationGrouping.KIND_INK }
        } else {
            all.filter { "pdf:${it.id}" == row.id }
        }
    }

    /** 点击条目 → 跳页（location 是 1-based，[jumpToPage] 收 0-based 索引）。 */
    private fun jumpToAnnotation(row: AnnotationRow) {
        val page = annotationsForRow(row).firstNotNullOfOrNull(::pageOf) ?: return
        annotationDrawer.hide()
        jumpToPage(page - 1)
    }

    /**
     * 编辑备注：复用「添加批注」的对话框写法，预填原文。
     *
     * 保存后置 `dirty = true` 并异步推送——`dirty` 是「新增或修改待上行」的唯一标记，
     * 下次 `pushAnnotations` 会把它 PUT 上去。
     */
    private fun editAnnotationRow(row: AnnotationRow) {
        val target = annotationsForRow(row).firstOrNull() ?: return
        val input = EditText(this).apply {
            setText(target.text)
            hint = getString(R.string.pdf_annotation_hint)
        }
        AlertDialog.Builder(this)
            .setTitle("编辑批注")
            .setView(input)
            .setPositiveButton(android.R.string.ok) { _, _ ->
                val text = input.text?.toString()?.trim().orEmpty()
                // 空备注不保存：服务端 kind=note 时 text 必填
                if (text.isEmpty()) return@setPositiveButton
                annotationStore.update(
                    target.copy(text = text, updatedAt = System.currentTimeMillis(), dirty = true),
                )
                enqueuePushAnnotations()
                refreshAnnotationDrawer()
            }
            .setNegativeButton(android.R.string.cancel, null)
            .show()
    }

    /**
     * 删除一条批注。
     *
     * **不要重复移除**：装配了 [syncManager] 时，本地移除与 `pendingDeletes` 入队都由
     * `SyncManager.deleteAnnotation` 完成（`serverId == null` 的记录不入队、不发 DELETE）。
     * 未装配同步（服务端未配置）时才由 [removeAnnotationRecord] 直接删本地，
     * 并把 `serverId` 落进队列等下次 flush。
     */
    private fun deleteAnnotationRow(row: AnnotationRow) {
        val target = annotationsForRow(row).firstOrNull() ?: return
        removeAnnotationRecord(target)
        // 在线时立刻补发 DELETE；离线/失败时队列仍在，下次 onStop 再 flush
        if (syncManager != null) enqueuePushDeletes()
        refreshAnnotationDrawer()
    }

    /**
     * 删除路径的**唯一执行点**：本地移除 + 判定是否要上行（抽屉、撤销/清空笔迹都走这里）。
     *
     * 有 [syncManager] 时交给 `SyncManager.deleteAnnotation`（它统一处理「入待删队列 vs 仅本地」）；
     * 没有时手工复现同一语义——`serverId == null` 的记录服务端不认识，不发 DELETE、不入队。
     */
    private fun removeAnnotationRecord(target: PdfAnnotation) {
        val manager = syncManager
        if (manager != null) {
            manager.deleteAnnotation(docId, target)
            return
        }
        annotationStore.remove(docId, target.id)
        val serverId = target.serverId
        val identity = uid
        if (serverId != null && !identity.isNullOrBlank()) {
            pendingDeletes.add(identity, serverId)
        }
    }

    /** 异步 flush 待删队列（无同步管理器时直接返回，零网络行为）。 */
    private fun enqueuePushDeletes() {
        val manager = syncManager ?: return
        val id = docId
        val executor = syncExecutor ?: return
        // 同 [enqueuePushProgress]：shutdown() 之后提交会被拒绝，异常一并兜住。
        runCatching {
            executor.execute {
                runCatching { manager.pushDeletes(id) }
                    .onFailure { Log.w(TAG, "推送批注删除失败（已忽略）", it) }
            }
        }.onFailure { Log.w(TAG, "同步任务提交失败（已忽略）", it) }
    }

    // ---- 书签（M10.10）----

    /** 当前页有书签则取消，否则添加（标题固定为「第 N 页」，1-based）。 */
    private fun toggleBookmark() {
        if (!::bookmarkStore.isInitialized) return
        val page = firstVisiblePage()
        if (bookmarkStore.has(docId, page)) {
            bookmarkStore.remove(docId, page)
            toast(getString(R.string.pdf_bookmark_removed))
        } else {
            val added = bookmarkStore.add(
                docId,
                PdfBookmark(page = page, title = "第 ${page + 1} 页", createdAt = System.currentTimeMillis()),
            )
            if (added) toast(getString(R.string.pdf_bookmark_added))
        }
        refreshBookmarkButton()
    }

    /**
     * 顶栏书签图标随当前页是否已有书签切换实心/空心。
     *
     * 调用点：翻页（[updateCurrentPage]）、初始定位、顶栏点击后、抽屉内增删后。
     * 只在「页发生变化」时被触发（[updateCurrentPage] 对同页提前返回），故每次一次 JSON 读
     * （[PdfBookmarkStore.list] 解析开销小、书签量级低）不会成为滚动热路径上的负担。
     */
    private fun refreshBookmarkButton() {
        if (!::bookmarkButton.isInitialized || !::bookmarkStore.isInitialized) return
        val has = bookmarkStore.has(docId, firstVisiblePage())
        bookmarkButton.setImageResource(
            if (has) R.drawable.ic_bookmark_filled else R.drawable.ic_bookmark_outline,
        )
    }

    /** 抽屉里的「增加新书签」：把当前页加入并刷新抽屉（保持书签标签页可见）。 */
    private fun onAddBookmarkFromDrawer() {
        val page = firstVisiblePage()
        bookmarkStore.add(
            docId,
            PdfBookmark(page = page, title = "第 ${page + 1} 页", createdAt = System.currentTimeMillis()),
        )
        refreshBookmarkButton()
        loadAndShowToc()
    }

    // ---- PdfInkHost ----

    override fun inkStrokes(page: Int): List<InkStroke> = inkStore.strokes(docId, page)

    /**
     * 一笔完成：**先**落盘到 [inkStore]（渲染真相），**再**登记一条 `kind=ink` 的同步镜像（M10.3 T6）。
     *
     * 顺序不可换：镜像只是同步载体，即使登记失败（页面尺寸取不到、store 异常）笔迹也必须已落盘，
     * 否则用户会「写完就消失」。
     */
    override fun onInkStrokeFinished(page: Int, stroke: InkStroke) {
        inkStore.appendStroke(docId, page, stroke)
        adapter?.refreshInk(page)
        updateInkChrome()
        registerInkMirror(page, stroke)
    }

    override fun isInkEnabled(): Boolean = inkEnabled

    /**
     * 把刚完成的一笔登记为一条 `kind=ink` 批注（同步镜像，不参与绘制）。
     *
     * **零网络 × 三重失败退化**：
     * - 页面尺寸取不到（渲染器已关闭 / 尺寸未算出）→ 直接跳过，不伪造坐标；
     * - 编码不出 location（点序列为空）→ 跳过；
     * - 本地已有同 `(kind, location, text)` 的批注 → 跳过（同一笔被重复回调时不会翻倍）。
     * 未装配同步（[syncManager] 为 `null`，即无 uid 或服务端未配置）时
     * [enqueuePushAnnotations] 直接返回，**零网络请求**；镜像仍在本地，下次打开带 uid 的书由补登推上去。
     *
     * @param page 页面索引，0-based（[PdfPageAdapter] 的 position）
     */
    private fun registerInkMirror(page: Int, stroke: InkStroke) {
        if (!::annotationStore.isInitialized) return
        val size = pageSizePt(page) ?: return
        val location = InkAnnotationMapper.inkLocation(page, stroke, size.first, size.second) ?: return
        val existing = annotationStore.list(docId)
        if (InkAnnotationMapper.isRegistered(existing, location)) return
        val stored = annotationStore.add(InkAnnotationMapper.inkAnnotation(docId, location))
        // 在线即上传；服务端按 (uid, kind, location, text) 幂等，重复 POST 不会产生重复批注
        enqueuePushAnnotations()
        // 抽屉开着时立即多出一行手写（否则要等下次打开抽屉）
        refreshAnnotationDrawer()
        Log.d(TAG, "登记手写批注 #${stored.id} ${stored.location}")
    }

    /**
     * 页索引（0-based）→ `(宽 pt, 高 pt)`；取不到返回 `null`。
     *
     * `PdfRenderer.Page.width/height` 即 PDF **point**（72 dpi 下 1:1），与渲染位图尺寸无关——
     * 适配器把位图缩放到 `renderWidth` 像素只是显示缩放，归一化坐标已消除该缩放。
     *
     * 两个注意点：
     * 1. **必须与适配器同一把锁**（`synchronized(renderer)`）：[PdfRenderer] 同一时刻只允许打开
     *    一个 Page，适配器在渲染线程里也是用同一把锁打开的，否则会抛 `IllegalStateException`；
     * 2. **结果缓存**：每落一笔 openPage 一次是纯浪费（同一页会写很多笔），故按页缓存；
     *    缓存随 Activity 生命周期，而 [renderer] 在同一生命周期内不变，故无失效问题。
     */
    private fun pageSizePt(page: Int): Pair<Double, Double>? {
        pageSizesPt[page]?.let { return it }
        val pdf = renderer ?: return null
        return try {
            val size = synchronized(pdf) {
                pdf.openPage(page).use { it.width.toDouble() to it.height.toDouble() }
            }
            pageSizesPt[page] = size
            size
        } catch (e: Exception) {
            // 渲染器已关闭 / 页索引越界：手写镜像登记降级为「跳过」，不影响笔迹本身
            Log.w(TAG, "读取第 $page 页尺寸失败（跳过手写镜像登记）", e)
            null
        }
    }

    // ---- 手写按钮 ----

    /**
     * 切换手写模式。
     *
     * 进入/退出有两条路径（M10.8）：顶栏「手写」按钮（本方法）、阅读区**双击**（见 [installTapPaging]）；
     * 手写模式下长按不弹菜单（落笔优先）。
     *
     * 开启后落笔优先占用点击与滑动（见 [installTapPaging]），故此时翻页改由阅读区滑动与双击退出
     * 手写后的底部进度条承担——原「手写时显示翻页按钮」的做法随工具栏改版取消（M10.8）。
     *
     * 进入手写时 [topChrome] 与 [bottomChrome] 一并隐藏（书写要整屏、浮层既挡内容又易误触），
     * 退出手写恢复显示并重算阅读区 padding；手写态的退出入口是面板上的 [inkExitButton]。
     */
    private fun toggleInk() {
        inkEnabled = !inkEnabled
        // 每次进入手写模式都是精简态：颜色折叠回「主 3 色」（更多颜色需再次展开）
        if (inkEnabled) {
            inkColorsExpanded = false
            findViewById<View>(R.id.inkColorsExtra).visibility = View.GONE
        }
        adapter?.setInkEnabled(inkEnabled)
        adapter?.setInkColor(inkColor)
        adapter?.setInkWidth(inkWidth)
        adapter?.setInkStyle(inkStyle)
        // 手写时隐藏上下浮层：书写要整屏空间，工具栏留在屏上既挡内容又容易误触
        val chromeVisibility = if (inkEnabled) View.GONE else View.VISIBLE
        topChrome.visibility = chromeVisibility
        bottomChrome.visibility = chromeVisibility
        applyContentPadding()
        updateInkChrome()
        // 浮层 GONE→VISIBLE 时 height 仍为 0（applyContentPadding 会提前返回），布局后再补一次
        topChrome.post { applyContentPadding() }
        // 重置后再刷一次选中态：若当前色属于「更多颜色」，会按 refreshInkPanelSelection 的
        // 自动展开逻辑重新展开该组，保证折叠态下也能看到当前色标（P1 遗留）
        refreshInkPanelSelection()
        toast(getString(if (inkEnabled) R.string.pdf_ink_toggle_on else R.string.pdf_ink_toggle))
    }

    /**
     * 撤销当前页最后一笔。
     *
     * 撤销后**镜像一并撤掉**（M10.3 T6）：[PdfInkStore] 是渲染真相，`kind=ink` 批注只是同步载体，
     * 笔迹没了载体必须跟着走，否则抽屉/服务端会留下「一笔幽灵手写」。
     * 被撤销的那一笔必须在 [PdfInkStore.undoLast] **之前**取出——撤销后它已不在 store 里，
     * 无法再算出它的 location。
     */
    private fun undoInk() {
        val page = firstVisiblePage()
        val undone = inkStore.strokes(docId, page).lastOrNull()
        if (inkStore.undoLast(docId, page)) {
            adapter?.refreshInk(page)
            if (undone != null) {
                val location = pageSizePt(page)?.let { (width, height) ->
                    InkAnnotationMapper.inkLocation(page, undone, width, height)
                }
                // 尺寸取不到时无法反算 location → 放弃撤镜像（笔迹本身已撤掉，不影响本地渲染）
                if (location != null) dropInkMirrors(page, only = location)
            }
        } else {
            toast(getString(R.string.pdf_ink_nothing_to_undo))
        }
        updateInkChrome()
    }

    /** 清除当前页全部笔迹（整页的 ink 镜像一并移除，理由见 [undoInk]）。 */
    private fun clearInk() {
        val page = firstVisiblePage()
        inkStore.clearPage(docId, page)
        adapter?.refreshInk(page)
        updateInkChrome()
        dropInkMirrors(page)
        toast(getString(R.string.pdf_ink_cleared))
    }

    /**
     * 笔迹被撤销/清除后，移除对应的 `kind=ink` 镜像批注（M10.3 T6）。
     *
     * **这不是新增的删除入口**：T5b 的抽屉里 ink 汇总行仍然置灰不可删，本方法只承接
     * 「用户已经通过手写工具栏明确删掉了笔迹」这一事实，把它同步到批注列表与服务端。
     * 删除走 [removeAnnotationRecord]：`serverId != null` 时入待删队列并发 DELETE，
     * 从未上传的只删本地；未装配同步时 [enqueuePushDeletes] 直接返回（零网络）。
     *
     * @param page 页面索引（0-based，与 [PdfInkStore] 同口径）
     * @param only 只处理该 location（撤销单笔）；`null` 表示该页全部（清空整页）
     */
    private fun dropInkMirrors(page: Int, only: String? = null) {
        if (!::annotationStore.isInitialized) return
        val targets = annotationStore.list(docId).filter { annotation ->
            annotation.kind == InkAnnotationMapper.KIND_INK &&
                pageOf(annotation) == page + 1 &&
                (only == null || annotation.location == only)
        }
        if (targets.isEmpty()) return
        targets.forEach { removeAnnotationRecord(it) }
        enqueuePushDeletes()
        refreshAnnotationDrawer()
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
        // 面板是右侧竖排浮动条（不属于顶部浮层），其显隐不改变顶部栏高度；
        // 仍重算一次以兼容 insets 变化与「手写态 → 非手写态」时的顶部高度切换。
        applyContentPadding()
    }

    /** 手写工具栏的点击接线（退出 / 更多颜色 / 颜色 / 粗细 / 笔型），选中的控件用 alpha 区分。 */
    private fun setupInkPanel() {
        inkExitButton.setOnClickListener {
            // 退出手写：面板随后由 updateInkChrome() 一并隐藏
            if (inkEnabled) toggleInk()
        }
        findViewById<View>(R.id.inkMoreButton).setOnClickListener {
            inkColorsExpanded = !inkColorsExpanded
            findViewById<View>(R.id.inkColorsExtra).visibility =
                if (inkColorsExpanded) View.VISIBLE else View.GONE
        }
        val colors = mapOf(
            R.id.inkColorRed to 0xFFE53935.toInt(),
            R.id.inkColorBlue to 0xFF1E88E5.toInt(),
            R.id.inkColorGreen to 0xFF43A047.toInt(),
            R.id.inkColorBlack to 0xFF424242.toInt(),
            R.id.inkColorOrange to 0xFFFB8C00.toInt(),
            R.id.inkColorPurple to 0xFF8E24AA.toInt(),
        )
        val borderPx = (1.5f * resources.displayMetrics.density).roundToInt()
        colors.forEach { (id, color) ->
            findViewById<View>(id).apply {
                background = GradientDrawable().apply {
                    shape = GradientDrawable.OVAL
                    setColor(color)
                    // 白色半透明描边：黑色色点在深色面板上也可见（真机截图曾整块消失）
                    setStroke(borderPx, 0x99FFFFFF.toInt())
                }
                setOnClickListener {
                    inkColor = color
                    adapter?.setInkColor(color)
                    refreshInkPanelSelection()
                }
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

    /**
     * 刷新面板选中态。
     *
     * 两类控件区分处理（M10.10 改成 56dp 图标条后，纯 alpha 的辨识度不够）：
     * - **颜色点**：保持 alpha 方案（选中 1.0 / 未选 0.55），不额外加边框；
     * - **图标按钮**（粗细 / 笔型，现为 [ImageView]）：选中 alpha 1.0 + 浅色高亮底块
     *   `#33FFFFFF`，未选中 alpha 0.45 + 透明底。高亮底会覆盖布局里的
     *   `selectableItemBackground`，属已知取舍（点击反馈由未选中态的底/水波纹承担）。
     */
    private fun refreshInkPanelSelection() {
        if (!::inkPanel.isInitialized) return
        val selectedColorId = when (inkColor) {
            0xFF1E88E5.toInt() -> R.id.inkColorBlue
            0xFF43A047.toInt() -> R.id.inkColorGreen
            0xFF424242.toInt() -> R.id.inkColorBlack
            0xFFFB8C00.toInt() -> R.id.inkColorOrange
            0xFF8E24AA.toInt() -> R.id.inkColorPurple
            else -> R.id.inkColorRed
        }
        // 选中的是「更多颜色」里的色时自动展开该组，否则折叠状态下看不到当前色标
        val extraIds = setOf(R.id.inkColorGreen, R.id.inkColorOrange, R.id.inkColorPurple)
        if (selectedColorId in extraIds && !inkColorsExpanded) {
            inkColorsExpanded = true
            findViewById<View>(R.id.inkColorsExtra).visibility = View.VISIBLE
        }
        val selectedWidthId = when {
            inkWidth <= 0.003f -> R.id.inkWidthThin
            inkWidth >= 0.006f -> R.id.inkWidthThick
            else -> R.id.inkWidthMedium
        }
        val selectedStyleId = when (inkStyle) {
            InkStyle.PEN -> R.id.inkStylePen
            InkStyle.MARKER -> R.id.inkStyleMarker
            InkStyle.HIGHLIGHTER -> R.id.inkStyleHighlighter
        }
        val colorIds = listOf(
            R.id.inkColorRed, R.id.inkColorBlue, R.id.inkColorGreen, R.id.inkColorBlack,
            R.id.inkColorOrange, R.id.inkColorPurple,
        )
        colorIds.forEach { id ->
            findViewById<View>(id).alpha = if (id == selectedColorId) 1f else 0.55f
        }
        val iconIds = listOf(
            R.id.inkWidthThin, R.id.inkWidthMedium, R.id.inkWidthThick,
            R.id.inkStylePen, R.id.inkStyleMarker, R.id.inkStyleHighlighter,
        )
        iconIds.forEach { id ->
            // 粗细与笔型各有一项选中，两组互不影响
            val selected = id == selectedWidthId || id == selectedStyleId
            findViewById<View>(id).apply {
                alpha = if (selected) 1f else 0.45f
                setBackgroundColor(if (selected) 0x33FFFFFF else Color.TRANSPARENT)
            }
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
        // 浮层收起时抽屉若开着也一并收起，避免「没有工具栏却浮着目录」的悬空态
        if (::tocDrawer.isInitialized && tocDrawer.isShowing) tocDrawer.hide()
        if (::annotationDrawer.isInitialized && annotationDrawer.isShowing) annotationDrawer.hide()
    }

    /**
     * 顶栏「目录」入口：抽屉已开则关闭（toggle），否则加载并显示。
     *
     * 拆成两个方法的原因：抽屉内的「增加书签 / 删除书签」需要**刷新已打开的抽屉**
     * （见 [loadAndShowToc]），若直接调本方法会被 toggle 逻辑挡住（开着 → 关掉）。
     */
    private fun showPdfToc() {
        if (::tocDrawer.isInitialized && tocDrawer.isShowing) {
            tocDrawer.hide()
            return
        }
        loadAndShowToc()
    }

    /**
     * 加载目录（后台解析）+ 书签列表并显示抽屉（不判断「是否已开」）。
     *
     * 数据链：书签树（PdfBox 解析，后台线程）→ [TocRows.forPdf]（行模型）→ [TocDrawer]（树形抽屉）。
     * 无书签的书回退「第 N 页」页码目录（[PdfOutlineReader.pageDirectory] 转成同构的树节点）。
     *
     * 本方法同时服务于「首次打开」与「书签增删后刷新」两个场景：TocDrawer 不持有书签列表，
     * 增删后必须重开一次才能反映新数据（见 TocDrawer.show 的「已显示则不做入场动画」）。
     */
    private fun loadAndShowToc() {
        if (tocLoading) return
        val uri = pdfUri
        if (uri == null) {
            toast(getString(R.string.reader_toc_empty))
            return
        }
        tocLoading = true
        val pageCount = lastPage + 1
        val currentPage = firstVisiblePage()
        val bookmarks = bookmarkStore.list(docId)
        ioExecutor.execute {
            val outline = runCatching { readOutline(uri) }.getOrDefault(emptyList())
            // 无书签 → 回退页码目录：把 FlatOutlineItem 转成同构树节点，复用同一套行模型
            val tree = outline.ifEmpty {
                PdfOutlineReader.pageDirectory(pageCount)
                    .map { PdfOutlineReader.PdfOutlineItem(it.title, it.pageIndex) }
            }
            val rows = TocRows.forPdf(tree)
            runOnUiThread {
                tocLoading = false
                if (isFinishing || isDestroyed) return@runOnUiThread
                if (rows.isEmpty()) {
                    toast(getString(R.string.reader_toc_empty))
                } else {
                    tocDrawer.show(
                        allRows = rows,
                        currentTarget = currentPage,
                        statusLine = getString(
                            R.string.pdf_toc_status,
                            currentPage + 1, pageCount, bookmarks.size,
                        ),
                        bookmarks = bookmarks,
                        onBookmarkAdd = { onAddBookmarkFromDrawer() },
                        onBookmarkDelete = { bookmark ->
                            bookmarkStore.remove(docId, bookmark.page)
                            refreshBookmarkButton()
                            // 抽屉不持有列表：删除后重新加载并刷新（保持当前标签页）
                            loadAndShowToc()
                        },
                    )
                }
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
        bookmarkStore.clearLegacy()
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
