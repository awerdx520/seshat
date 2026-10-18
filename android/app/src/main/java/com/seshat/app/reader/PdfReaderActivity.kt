package com.seshat.app.reader

import android.content.Context
import android.content.Intent
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
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
import java.io.IOException

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
 * 通过 [intent] 工厂方法构造。
 *
 * 持久化：
 * - 阅读进度 → [PdfProgressStore]，键 `pdf_progress_<docId>`。
 * - 批注     → [PdfAnnotationStore]，键 `pdf_annotations_<docId>`。
 * 两者共用 `SharedPreferences("pdf_reader")`，与 epub 侧键空间隔离。
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
        docId = uri.toString()

        val prefs = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        progressStore = PdfProgressStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
        )
        annotationStore = PdfAnnotationStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
        )
        inkStore = PdfInkStore(
            read = { prefs.getString(it, null) },
            write = { key, value -> prefs.edit().putString(key, value).apply() },
        )

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
    }

    override fun onDestroy() {
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

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        /** Intent 中携带 PDF Uri 的键。 */
        const val EXTRA_URI: String = "com.seshat.app.reader.EXTRA_URI"

        /** 与 epub 侧共享同一 SharedPreferences 文件，但键命名空间不同。 */
        const val PREFS_NAME: String = "pdf_reader"

        private const val DEFAULT_RENDER_WIDTH = 1080

        /** 浮层工具栏的初始内边距（dp），与布局 `activity_pdf_reader.xml` 中 `padding="6dp"` 对应。 */
        private const val INITIAL_CHROME_PADDING_DP = 6

        /** `savedInstanceState` 中手写开关的键。 */
        private const val STATE_INK_ENABLED = "state_ink_enabled"

        /** 构造进入阅读器的 Intent。 */
        fun intent(context: Context, uri: Uri): Intent =
            Intent(context, PdfReaderActivity::class.java).putExtra(EXTRA_URI, uri)
    }
}
