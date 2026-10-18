package com.seshat.app.ui

import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.AdapterView
import android.widget.ArrayAdapter
import android.widget.ImageView
import android.widget.ProgressBar
import android.widget.Spinner
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.google.android.material.button.MaterialButton
import com.seshat.app.R
import com.seshat.app.importer.BookImporter
import com.seshat.app.reader.BookFilter
import com.seshat.app.reader.BookItem
import com.seshat.app.reader.BookShelfLogic
import com.seshat.app.reader.BookSort
import com.seshat.app.reader.BookType
import com.seshat.app.reader.CoverCache
import com.seshat.app.reader.EpubReaderActivity
import com.seshat.app.reader.PdfReaderActivity
import com.seshat.app.reader.openBookLibrary
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 阅读 tab：本地书架网格（M10.6 B3d）。
 *
 * 数据流：`filesDir/books/` → [openBookLibrary] 扫描（后台线程）→ 过滤/排序 → [BookGridAdapter]。
 * 交互：点书 → epub 进 [EpubReaderActivity]、pdf 进 [PdfReaderActivity]；底部保留
 * 「导入文件 / 选择 EPUB 文件 / 打开示例 EPUB」三个入口。
 *
 * 线程约定：扫描与封面解码都在 [scanExecutor]（单线程）上串行执行，结果回主线程更新 UI；
 * 视图回调统一用 `isAdded` 与 `imageView.tag` 做有效性/复用校验。
 */
class ReaderFragment : Fragment() {

    /** 书库全量列表（未过滤）；过滤/排序在内存中做，避免每次切过滤条件都重新扫描磁盘。 */
    private var allItems: List<BookItem> = emptyList()

    private var filter: BookFilter = BookFilter.ALL

    private var sort: BookSort = BookSort.RECENT

    /** 封面缓存；[onDestroyView] 置空并关闭。 */
    private var coverCache: CoverCache? = null

    /** 单线程 executor：书库扫描与封面解码串行执行（PdfRenderer 非线程安全）。 */
    private var scanExecutor: ExecutorService? = null

    private var loading = false

    private lateinit var adapter: BookGridAdapter

    private lateinit var grid: RecyclerView

    private lateinit var shelfEmpty: TextView

    private lateinit var shelfLoading: ProgressBar

    /** 系统文档选择器：选择本地 epub 后直接打开（不进书库）。 */
    private val pickEpub =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri != null) {
                startActivity(EpubReaderActivity.intentForUri(requireContext(), uri))
            }
        }

    /** 系统文档选择器：经 [BookImporter] 导入书籍到应用私有阅读库，成功后刷新书架。 */
    private val pickImport =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri == null) return@registerForActivityResult
            val result = BookImporter(requireContext()).import(uri)
            Toast.makeText(requireContext(), result.message, Toast.LENGTH_LONG).show()
            refresh()
        }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_reader, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        coverCache = CoverCache.open(requireContext())
        scanExecutor = Executors.newSingleThreadExecutor()

        grid = view.findViewById(R.id.bookGrid)
        shelfEmpty = view.findViewById(R.id.shelfEmpty)
        shelfLoading = view.findViewById(R.id.shelfLoading)

        setupGrid()
        setupSpinners(view)

        view.findViewById<MaterialButton>(R.id.openSampleButton).setOnClickListener {
            openSampleEpub()
        }
        view.findViewById<MaterialButton>(R.id.pickEpubButton).setOnClickListener {
            // 部分文档提供方不返回 epub 专用 MIME，放开为任意类型以免选不到文件。
            pickEpub.launch(arrayOf("*/*"))
        }
        view.findViewById<MaterialButton>(R.id.importButton).setOnClickListener {
            pickImport.launch(arrayOf("*/*"))
        }

        refresh()
    }

    override fun onResume() {
        super.onResume()
        // 从阅读器返回后进度已变化，重新扫描以刷新进度徽标。
        // 首次进入时 onViewCreated 已发起扫描（loading 为 true），此处跳过避免重复扫描。
        if (::grid.isInitialized && !loading) refresh()
    }

    override fun onDestroyView() {
        scanExecutor?.shutdownNow()
        scanExecutor = null
        coverCache?.shutdown()
        coverCache = null
        super.onDestroyView()
    }

    // ---- 初始化 ----

    /** 网格列数按屏幕宽度决定（手机 2/3 列，平板 4 列）。 */
    private fun setupGrid() {
        grid.layoutManager = GridLayoutManager(requireContext(), spanCount())
        adapter = BookGridAdapter(
            onClick = { openBook(it) },
            coverLoader = { item, imageView -> loadCover(item, imageView) },
        )
        grid.adapter = adapter
    }

    private fun spanCount(): Int {
        val widthDp = resources.configuration.screenWidthDp
        return when {
            widthDp >= 600 -> 4
            widthDp >= 400 -> 3
            else -> 2
        }
    }

    /** 初始化过滤/排序下拉；首次选中会触发一次刷新（数据未就绪时等价空操作）。 */
    private fun setupSpinners(view: View) {
        val filterLabels = BookFilter.entries.map { getString(filterLabelOf(it)) }
        val filterAdapter =
            ArrayAdapter(requireContext(), android.R.layout.simple_spinner_item, filterLabels)
        filterAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        view.findViewById<Spinner>(R.id.filterSpinner).apply {
            adapter = filterAdapter
            setSelection(BookFilter.entries.indexOf(filter))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(
                    parent: AdapterView<*>?,
                    selected: View?,
                    position: Int,
                    id: Long,
                ) {
                    filter = BookFilter.entries[position]
                    applyFilter()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }

        val sortLabels = BookSort.entries.map { getString(sortLabelOf(it)) }
        val sortAdapter =
            ArrayAdapter(requireContext(), android.R.layout.simple_spinner_item, sortLabels)
        sortAdapter.setDropDownViewResource(android.R.layout.simple_spinner_dropdown_item)
        view.findViewById<Spinner>(R.id.sortSpinner).apply {
            adapter = sortAdapter
            setSelection(BookSort.entries.indexOf(sort))
            onItemSelectedListener = object : AdapterView.OnItemSelectedListener {
                override fun onItemSelected(
                    parent: AdapterView<*>?,
                    selected: View?,
                    position: Int,
                    id: Long,
                ) {
                    sort = BookSort.entries[position]
                    applyFilter()
                }

                override fun onNothingSelected(parent: AdapterView<*>?) = Unit
            }
        }
    }

    // ---- 数据 ----

    /**
     * 重新扫描书库（后台线程）。
     *
     * 扫描含 epub 解压解析与 PDF 页数读取，240 本书可能耗时数秒，故必须离开主线程；
     * 回调统一回主线程，并用 `isAdded` 防止视图销毁后更新。
     */
    private fun refresh() {
        val executor = scanExecutor ?: return
        setLoading(true)
        val library = openBookLibrary(requireContext())
        val submitted = runCatching {
            executor.execute {
                val items = runCatching { library.load(BookFilter.ALL, BookSort.RECENT) }
                    .getOrDefault(emptyList())
                activity?.runOnUiThread {
                    if (!isAdded) return@runOnUiThread
                    allItems = items
                    setLoading(false)
                    applyFilter()
                }
            }
        }.isSuccess
        // executor 已关闭（视图销毁竞态）：直接收尾，避免进度条卡住
        if (!submitted) setLoading(false)
    }

    /** 按当前过滤/排序条件刷新网格（纯内存操作，主线程执行）。 */
    private fun applyFilter() {
        val shown = BookShelfLogic.sort(
            sort,
            allItems.filter { BookShelfLogic.matches(filter, it.percent) },
        )
        adapter.submit(shown)
        shelfEmpty.visibility = if (shown.isEmpty() && !loading) View.VISIBLE else View.GONE
    }

    private fun setLoading(show: Boolean) {
        loading = show
        if (!::shelfLoading.isInitialized) return
        shelfLoading.visibility = if (show) View.VISIBLE else View.GONE
        if (show) shelfEmpty.visibility = View.GONE
    }

    /** 后台解码封面，回主线程 set；`tag` 校验保证视图被复用时不会串封面。 */
    private fun loadCover(item: BookItem, imageView: ImageView) {
        val cache = coverCache ?: return
        val executor = scanExecutor ?: return
        val sizePx = (COVER_SIZE_DP * resources.displayMetrics.density).toInt()
        runCatching {
            executor.execute {
                val bitmap = runCatching { cache.load(item.file, item.type, sizePx, sizePx) }
                    .getOrNull()
                activity?.runOnUiThread {
                    // 视图可能已被复用给另一本书：只在该视图仍代表同一本书时 set
                    if (isAdded && imageView.tag == item.progressKey) {
                        imageView.setImageBitmap(bitmap)
                    }
                }
            }
        }
    }

    // ---- 交互 ----

    /** 打开一本书：epub 走文件路径 Intent，pdf 走 `file://` Uri。 */
    private fun openBook(item: BookItem) {
        val context = requireContext()
        when (item.type) {
            BookType.EPUB ->
                startActivity(EpubReaderActivity.intentForFile(context, item.file))

            BookType.PDF ->
                startActivity(PdfReaderActivity.intent(context, Uri.fromFile(item.file)))
        }
    }

    /**
     * 把 assets/sample.epub 复制到书籍目录（`filesDir/books/`）后打开。
     *
     * 旧版曾复制到 `filesDir/sample.epub`（根目录），该文件刻意不删除作为回滚点；
     * 由于 epub 进度键是内容哈希，迁移后同一本书的阅读进度仍然可见。
     */
    private fun openSampleEpub() {
        val context = requireContext()
        val target = File(BookImporter(context).booksDir(), SAMPLE_ASSET)
        if (!target.exists() || target.length() == 0L) {
            try {
                context.assets.open(SAMPLE_ASSET).use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: Exception) {
                Toast.makeText(
                    context,
                    getString(R.string.reader_open_failed, e.message ?: SAMPLE_ASSET),
                    Toast.LENGTH_LONG,
                ).show()
                return
            }
            // 新书入库：刷新书架后用户可从网格再次打开
            refresh()
        }
        startActivity(EpubReaderActivity.intentForFile(context, target))
    }

    /** 过滤条件 → 文案。 */
    private fun filterLabelOf(value: BookFilter): Int = when (value) {
        BookFilter.ALL -> R.string.shelf_filter_all
        BookFilter.UNREAD -> R.string.shelf_filter_unread
        BookFilter.READING -> R.string.shelf_filter_reading
        BookFilter.FINISHED -> R.string.shelf_filter_finished
    }

    /** 排序方式 → 文案。 */
    private fun sortLabelOf(value: BookSort): Int = when (value) {
        BookSort.RECENT -> R.string.shelf_sort_recent
        BookSort.TITLE -> R.string.shelf_sort_title
        BookSort.IMPORT_TIME -> R.string.shelf_sort_import
    }

    private companion object {
        const val SAMPLE_ASSET = "sample.epub"

        /** 封面期望边长（dp）；与 item_book_card.xml 的固定高度 150dp 对齐。 */
        const val COVER_SIZE_DP = 150
    }
}
