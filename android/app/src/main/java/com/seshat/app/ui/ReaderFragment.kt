package com.seshat.app.ui

import android.content.Context
import android.net.Uri
import android.os.Bundle
import android.os.SystemClock
import android.util.Log
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
import com.seshat.app.reader.BookDownloader
import com.seshat.app.reader.BookFilter
import com.seshat.app.reader.BookItem
import com.seshat.app.reader.BookShelfLogic
import com.seshat.app.reader.BookSort
import com.seshat.app.reader.BookType
import com.seshat.app.reader.CoverCache
import com.seshat.app.reader.DownloadResult
import com.seshat.app.reader.EpubReaderActivity
import com.seshat.app.reader.PdfReaderActivity
import com.seshat.app.reader.RemoteBook
import com.seshat.app.reader.RemoteBookSource
import com.seshat.app.reader.RestFileDownloadApi
import com.seshat.app.reader.openBookLibrary
import com.seshat.app.sync.ResourceEntry
import com.seshat.app.sync.RestClient
import com.seshat.app.sync.SyncCoordinator
import com.seshat.app.sync.SyncHolder
import com.seshat.app.sync.SyncOutcome
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 阅读 tab：书架网格（M10.6 B3d + M9.2 B 批远端数据源）。
 *
 * 数据流：`filesDir/books/` → [openBookLibrary] 扫描（后台线程）+ [SyncHolder] 的
 * [com.seshat.app.sync.ResourceIndex] 远端清单 → 过滤/排序 → [BookGridAdapter]。
 * 远端有、本地无的书显示为「未下载」占位；点击时按需下载（[BookDownloader]）后再打开。
 *
 * 交互：点书 → epub 进 [EpubReaderActivity]、pdf 进 [PdfReaderActivity]（**带 uid**，服务端配置存在时
 * 阅读进度按资源 uid 同步）；底部保留「导入文件 / 选择 EPUB 文件 / 打开示例 EPUB」三个入口，
 * 导入成功且 ≤32 MiB 时后台上传到 mirror 根。
 *
 * 线程约定：扫描、封面解码、下载、上传都在 [scanExecutor]（单线程）上串行执行，结果回主线程更新 UI；
 * 同步则跑在 [SyncHolder] 持有的进程级单线程 executor 上（见 [SyncCoordinator]），两者互不阻塞。
 * 视图回调统一用 `isAdded` 与 `imageView.tag` 做有效性/复用校验。
 */
class ReaderFragment : Fragment() {

    /** 书库全量列表（未过滤）；过滤/排序在内存中做，避免每次切过滤条件都重新扫描磁盘。 */
    private var allItems: List<BookItem> = emptyList()

    private var filter: BookFilter = BookFilter.ALL

    private var sort: BookSort = BookSort.RECENT

    /** 封面缓存；[onDestroyView] 置空并关闭。 */
    private var coverCache: CoverCache? = null

    /** 单线程 executor：书库扫描、封面解码、下载与上传串行执行（PdfRenderer 非线程安全）。 */
    private var scanExecutor: ExecutorService? = null

    private var loading = false

    /** 正在下载的文件名集合（`file.name`）；交给 adapter 显示「下载中…」。 */
    private val downloading = mutableSetOf<String>()

    /** 同步编排器（进程级单例，由 [SyncHolder] 提供；不在本类关闭其 executor）。 */
    private var syncCoordinator: SyncCoordinator? = null

    /** 按需下载器（[onViewCreated] 装配）。 */
    private lateinit var bookDownloader: BookDownloader

    /** 上次触发同步的时刻（`elapsedRealtime`），用于 [syncNow] 的非强制路径（[onResume]）限流。 */
    private var lastSyncAt = 0L

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

    /**
     * 系统文档选择器：经 [BookImporter] 导入书籍到应用私有阅读库，成功后刷新书架并尝试上传。
     *
     * 上传是**尽力而为**：未配置服务端时零网络静默跳过；失败只提示，本地文件保留。
     */
    private val pickImport =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri == null) return@registerForActivityResult
            val result = BookImporter(requireContext()).import(uri)
            Toast.makeText(requireContext(), result.message, Toast.LENGTH_LONG).show()
            refresh()
            val imported = result.importedPath
            if (result.success && imported != null) uploadImported(File(imported))
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
        // 同步装配全进程唯一（ResourceIndex 的 @Synchronized 是实例锁，见 SyncHolder）
        syncCoordinator = SyncHolder.coordinator(requireContext())
        // 用 applicationContext 捕获：apiFactory 在后台线程被调用，不能依赖 Fragment 仍附着
        val appContext = requireContext().applicationContext
        bookDownloader = BookDownloader(BookImporter(appContext).booksDir()) {
            SyncHolder.restClient(appContext)?.let { RestFileDownloadApi(it) }
        }

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
        // 首次进入强制同步一次（客户端无下拉刷新，进入即拉最新清单）
        syncNow(force = true)
    }

    override fun onResume() {
        super.onResume()
        // 从阅读器返回后进度已变化，重新扫描以刷新进度徽标。
        // 首次进入时 onViewCreated 已发起扫描（loading 为 true），此处跳过避免重复扫描。
        if (::grid.isInitialized && !loading) refresh()
        // 同步按 30s 限流：切回书架不每次都打网络
        syncNow(force = false)
    }

    /**
     * tab 显隐切换回调（`MainActivity` 用 `show`/`hide` 切 tab，**不会**触发 [onResume]）。
     *
     * 切回本 tab 时强制同步一次（绕过 [SYNC_MIN_INTERVAL_MS] 限流），使服务端 move/改名后
     * 本地索引与 `files/books/` 能跟随；`SyncOutcome.Ok` 分支内部已 `refresh()`，故不重复扫描。
     */
    override fun onHiddenChanged(hidden: Boolean) {
        super.onHiddenChanged(hidden)
        if (!hidden) syncNow(force = true)
    }

    override fun onDestroyView() {
        scanExecutor?.shutdownNow()
        scanExecutor = null
        coverCache?.shutdown()
        coverCache = null
        // 注意：不关闭 SyncHolder 的 executor——它是进程级的，由 SyncHolder 持有
        super.onDestroyView()
    }

    // ---- 初始化 ----

    /** 网格列数按屏幕宽度决定（手机 2/3 列，平板 4 列）。 */
    private fun setupGrid() {
        grid.layoutManager = GridLayoutManager(requireContext(), spanCount())
        adapter = BookGridAdapter(
            onClick = { onItemClick(it) },
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
     *
     * M9.2 B 批起同时合并远端清单（[remoteBooks]）：远端有、本地无的书以「未下载」占位出现。
     */
    private fun refresh() {
        val executor = scanExecutor ?: return
        // 后台线程里不能再调用 requireContext()：先把 applicationContext 与协调器抓成局部量
        val appContext = requireContext().applicationContext
        val coordinator = syncCoordinator
        setLoading(true)
        val library = openBookLibrary(appContext, remote = { remoteBooks(appContext, coordinator) })
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

    /**
     * 远端清单：`roots()` 逐根取 [RemoteBookSource.fromIndex] 的结果并拼平。
     *
     * 未配置服务端时 `roots()` 返回空表（零网络）→ 结果为空 → 书架退化为纯本地（优雅降级）。
     * **注意**：本函数在扫描线程上执行，`roots()` 首次调用可能触发一次 `/api/roots` 网络请求。
     */
    private fun remoteBooks(
        appContext: Context,
        coordinator: SyncCoordinator?,
    ): List<RemoteBook> {
        if (coordinator == null) return emptyList()
        val index = SyncHolder.index(appContext)
        return coordinator.roots().flatMap { root -> RemoteBookSource.fromIndex(index, root.tag) }
    }

    /** 按当前过滤/排序条件刷新网格（纯内存操作，主线程执行）。 */
    private fun applyFilter() {
        val shown = BookShelfLogic.sort(
            sort,
            allItems.filter { BookShelfLogic.matches(filter, it.percent) },
        )
        adapter.submit(shown, downloading)
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

    /** 点击一本书：已下载直接打开；远端未下载则按需下载后再打开。 */
    private fun onItemClick(item: BookItem) {
        if (item.isDownloaded) openBook(item) else startDownload(item)
    }

    /**
     * 打开一本书：epub 走文件路径 Intent，pdf 走 `file://` Uri。
     *
     * **必须带 uid**：有服务端配置时阅读器据此读写「按资源 uid」的进度；
     * `uid == null`（纯本地书、远端清单不可用）时阅读器退回本地键（M9.2 A 批行为）。
     */
    private fun openBook(item: BookItem) {
        val context = requireContext()
        when (item.type) {
            BookType.EPUB ->
                startActivity(EpubReaderActivity.intentForFile(context, item.file, item.uid))

            BookType.PDF ->
                startActivity(PdfReaderActivity.intent(context, Uri.fromFile(item.file), item.uid))
        }
    }

    /**
     * 按需下载一本远端书并打开（M9.2 B 批）。
     *
     * 流程：标记 [downloading] → 后台 [BookDownloader.ensureLocal] → 主线程收尾。
     * `Ready` 时先 [refresh]（本地文件 mtime/长度已变，需重新扫描取真实元数据），
     * 再以 `item.copy(file = 下载产物, isDownloaded = true)` 打开——`uid` 原样保留，
     * 保证阅读进度按远端资源身份归档。
     */
    private fun startDownload(item: BookItem) {
        val remote = item.remote ?: return // isDownloaded=false 的条目必带 remote；防御性早退
        val name = item.file.name
        if (!downloading.add(name)) return // 已在下载中：忽略重复点击
        applyFilter() // 立刻显示「下载中…」
        val executor = scanExecutor ?: return
        val downloader = bookDownloader
        runCatching {
            executor.execute {
                val result = downloader.ensureLocal(remote)
                activity?.runOnUiThread {
                    if (!isAdded) return@runOnUiThread
                    downloading -= name
                    when (result) {
                        is DownloadResult.Ready -> {
                            refresh()
                            openBook(item.copy(file = result.file, isDownloaded = true))
                        }

                        DownloadResult.NotConfigured ->
                            toast(R.string.book_download_not_configured)

                        is DownloadResult.Failed ->
                            toast(R.string.book_download_failed, result.message)
                    }
                }
            }
        }.onFailure {
            // executor 已关闭（视图销毁竞态）：清标记，避免徽标永久卡在「下载中…」
            downloading -= name
            applyFilter()
        }
    }

    /**
     * 把刚导入的本地书上传到服务端 mirror 根（尽力而为）。
     *
     * 规则：超 [RestClient.MAX_UPLOAD_BYTES] → 只提示不传；未配置服务端 → 静默跳过（零网络）；
     * 根清单里没有 mirror 根（只有只读的 ondemand 根）→ 静默跳过；
     * 失败 → 提示但**本地文件保留**。成功后把返回的 uid/元数据写入 [ResourceIndex] 并刷新书架，
     * 使该条目后续能按 uid 同步进度。
     */
    private fun uploadImported(file: File) {
        if (file.length() > RestClient.MAX_UPLOAD_BYTES) {
            toast(R.string.book_upload_too_large)
            return
        }
        val appContext = requireContext().applicationContext
        val coordinator = syncCoordinator
        val executor = scanExecutor ?: return
        runCatching {
            executor.execute {
                val rest = SyncHolder.restClient(appContext) ?: return@execute // 未配置：静默
                val roots = coordinator?.roots().orEmpty()
                // 上传只能落可写根（mirror）；优先服务端默认根
                val root = (roots.firstOrNull { it.mode == MIRROR_MODE && it.isDefault }
                    ?: roots.firstOrNull { it.mode == MIRROR_MODE })?.tag ?: return@execute
                val result = runCatching {
                    val resp = rest.uploadFile(root, file.name, file.readBytes(), ifNoneMatch = "*")
                    SyncHolder.index(appContext).upsertAll(
                        listOf(
                            ResourceEntry(
                                uid = resp.uid,
                                root = resp.root.ifBlank { root },
                                path = resp.path.ifBlank { file.name },
                                blob = resp.blob,
                                size = file.length(),
                                mtime = file.lastModified(),
                            ),
                        ),
                    )
                }
                activity?.runOnUiThread {
                    if (!isAdded) return@runOnUiThread
                    result.onSuccess { refresh() }.onFailure {
                        toast(R.string.book_upload_failed, it.message ?: it.javaClass.simpleName)
                    }
                }
            }
        }.onFailure { Log.w(TAG, "上传任务提交失败（executor 已关闭）", it) }
    }

    // ---- 同步 ----

    /**
     * 触发一次同步（异步，不阻塞 UI）。
     *
     * `force = false` 时按 [SYNC_MIN_INTERVAL_MS] 限流：`onResume` 频繁切回书架不每次都打网络。
     * `force = true` 跳过限流（首次进入、切回本 tab 见 [onHiddenChanged]）。
     * `NotConfigured` 静默（服务端是可选能力）；失败只记日志，不打扰用户（书架已有本地数据）。
     */
    private fun syncNow(force: Boolean) {
        val coordinator = syncCoordinator ?: return
        val now = SystemClock.elapsedRealtime()
        if (!force && lastSyncAt != 0L && now - lastSyncAt < SYNC_MIN_INTERVAL_MS) return
        lastSyncAt = now
        coordinator.syncNow { outcome ->
            activity?.runOnUiThread {
                if (!isAdded) return@runOnUiThread
                when (outcome) {
                    is SyncOutcome.Ok -> refresh()
                    SyncOutcome.NotConfigured -> Unit
                    is SyncOutcome.Failed -> Log.w(TAG, "同步失败：${outcome.message}")
                }
            }
        }
    }

    /** 统一 Toast 出口（带格式化参数时走 [getString] 的变参重载）。 */
    private fun toast(resId: Int, vararg args: Any) {
        val text = if (args.isEmpty()) getString(resId) else getString(resId, *args)
        Toast.makeText(requireContext(), text, Toast.LENGTH_LONG).show()
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

        /** 日志标签。 */
        const val TAG = "ReaderFragment"

        /** `onResume` 触发同步的最小间隔：30s（切回书架不每次都打网络）。 */
        const val SYNC_MIN_INTERVAL_MS = 30_000L

        /** 可写根的服务端 mode 值（上传只能落这种根；`ondemand` 根只读）。 */
        const val MIRROR_MODE = "mirror"
    }
}
