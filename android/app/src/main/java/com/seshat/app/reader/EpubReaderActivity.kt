package com.seshat.app.reader

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.view.ViewGroup
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.FragmentActivity
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.seshat.app.R
import java.io.File

/**
 * epub 阅读界面（MVP）。
 *
 * - 章节内容：WebView 显示当前章节 HTML，资源经 https 虚拟域（[EPUB_ASSET_DOMAIN]）由内存 zip 提供；
 * - 章节导航：ViewPager2 左右滑动 + 底部「上一章/下一章」按钮；
 * - 顶部显示「第 n/N 章 · 标题」；
 * - 退出/翻页时持久化进度，工具栏「批注」按钮把选中文本存为批注。
 *
 * epub 打开流程（后台线程）：读取字节 → 解析（[EpubParser]）→ 计算文档 id（[documentIdOf]）→ 装配 Pager。
 */
class EpubReaderActivity : AppCompatActivity() {

    /** 当前书籍的内存 zip 源（WebView 资源处理器复用同一份，只读）。 */
    var epubSource: EpubSource? = null
        private set

    /** 文档标识（内容哈希），进度/批注的持久化 key。 */
    var documentId: String = ""
        private set

    private lateinit var chapterTitleView: TextView
    private lateinit var pager: ViewPager2
    private lateinit var progressStore: ReadingProgressStore
    private lateinit var annotationStore: AnnotationStore

    private var book: EpubBook? = null
    private val scrollByChapter = HashMap<Int, Int>()

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_epub_reader)

        chapterTitleView = findViewById(R.id.chapterTitleView)
        pager = findViewById(R.id.chapterPager)
        progressStore = ReadingProgressStore(this)
        annotationStore = AnnotationStore(this)

        findViewById<Button>(R.id.prevChapterButton).setOnClickListener { moveBy(-1) }
        findViewById<Button>(R.id.nextChapterButton).setOnClickListener { moveBy(1) }
        findViewById<Button>(R.id.annotateButton).setOnClickListener { addAnnotationFromSelection() }

        pager.registerOnPageChangeCallback(
            object : ViewPager2.OnPageChangeCallback() {
                override fun onPageSelected(position: Int) {
                    updateChapterTitle(position)
                    persistProgress(position)
                }
            },
        )

        chapterTitleView.text = getString(R.string.reader_loading)
        openBook()
    }

    override fun onPause() {
        super.onPause()
        if (book != null) persistProgress(pager.currentItem)
    }

    // ---- 供 ChapterFragment 使用 ----

    fun chapterAt(index: Int): EpubChapter? = book?.chapters?.getOrNull(index)

    /** 读取章节 HTML（内存 zip，读取为本地内存操作）。 */
    fun readChapterHtml(chapter: EpubChapter): String? {
        val bytes = epubSource?.read(chapter.href) ?: return null
        return String(bytes, Charsets.UTF_8)
    }

    fun savedScrollY(chapterIndex: Int): Int = scrollByChapter[chapterIndex] ?: 0

    fun onChapterScrolled(chapterIndex: Int, scrollY: Int) {
        scrollByChapter[chapterIndex] = scrollY
    }

    /** 章节总数（供适配器使用）。 */
    fun chapterCount(): Int = book?.chapters?.size ?: 0

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

        pager.adapter = ChapterPagerAdapter(this, parsed.chapters.size)
        val saved = progressStore.load(docId)
        val startIndex = saved?.chapterIndex?.coerceIn(0, parsed.chapters.size - 1) ?: 0
        if (saved != null) scrollByChapter[startIndex] = saved.scrollY
        pager.setCurrentItem(startIndex, false)
        updateChapterTitle(startIndex)
    }

    // ---- 导航与标题 ----

    private fun moveBy(delta: Int) {
        val count = chapterCount()
        if (count == 0) return
        val target = (pager.currentItem + delta).coerceIn(0, count - 1)
        if (target != pager.currentItem) pager.setCurrentItem(target, true)
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
