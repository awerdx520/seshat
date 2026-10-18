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
import com.seshat.app.R
import com.seshat.app.settings.AppPreferences
import com.seshat.app.settings.ReaderPageMode
import java.io.File

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

    /** 文档标识（内容哈希），进度/批注的持久化 key。 */
    var documentId: String = ""
        private set

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

    override fun onDestroy() {
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
        title = parsed.title

        // 横向容器始终装配（竖向模式下不可见，也无副作用）。
        pager.adapter = ChapterPagerAdapter(this, parsed.chapters.size)

        val saved = progressStore.load(docId)
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
        if (documentId.isBlank() || book == null) return
        progressStore.save(
            ReadingProgress(
                documentId = documentId,
                chapterIndex = chapterIndex,
                scrollY = scrollByChapter[chapterIndex] ?: 0,
            ),
        )
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
                        documentId = documentId,
                        chapterIndex = chapterIndex,
                        selectedText = selectedText,
                        note = input.text.toString(),
                    ),
                )
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
        const val EXTRA_EPUB_PATH = "extra_epub_path"
        const val EXTRA_EPUB_URI = "extra_epub_uri"

        /** 以本地文件路径打开（示例 epub 用）。 */
        fun intentForFile(context: Context, file: File): Intent =
            Intent(context, EpubReaderActivity::class.java).putExtra(EXTRA_EPUB_PATH, file.absolutePath)

        /** 以 content Uri 打开（SAF 选择的 epub 用）。 */
        fun intentForUri(context: Context, uri: Uri): Intent =
            Intent(context, EpubReaderActivity::class.java).putExtra(EXTRA_EPUB_URI, uri.toString())
    }
}
