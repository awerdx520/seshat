package com.notes.app.reader

import android.content.Context
import android.content.Intent
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ParcelFileDescriptor
import android.widget.Button
import android.widget.EditText
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog
import androidx.appcompat.app.AppCompatActivity
import androidx.viewpager2.widget.ViewPager2
import com.notes.app.R
import java.io.IOException

/**
 * PDF 阅读器（M3.3 MVP）。
 *
 * 渲染方案：使用 Android 系统内置的 [PdfRenderer]（API 21+，无需第三方 JNI 库），
 * 逐页渲染为 Bitmap，交由 [PdfPageAdapter] 在 [ViewPager2] 中横滑翻页，
 * 底部 [TextView] 显示「当前页 / 总页数」。
 *
 * 入口：Intent 携带 [EXTRA_URI]（`content://` 或 `file://` 的 PDF Uri），
 * 通过 [intent] 工厂方法构造。
 *
 * 持久化：
 * - 阅读进度 → [PdfProgressStore]，键 `pdf_progress_<docId>`。
 * - 批注     → [PdfAnnotationStore]，键 `pdf_annotations_<docId>`。
 * 两者共用 `SharedPreferences("pdf_reader")`，与 epub 侧键空间隔离。
 */
class PdfReaderActivity : AppCompatActivity() {

    private lateinit var pager: ViewPager2
    private lateinit var pageIndicator: TextView

    private var renderer: PdfRenderer? = null
    private var fileDescriptor: ParcelFileDescriptor? = null
    private var adapter: PdfPageAdapter? = null
    private var docId: String = ""

    private lateinit var progressStore: PdfProgressStore
    private lateinit var annotationStore: PdfAnnotationStore

    /** 翻页回调：更新页码指示并持久化进度。 */
    private val onPageChanged = object : ViewPager2.OnPageChangeCallback() {
        override fun onPageSelected(position: Int) {
            updateIndicator(position)
            saveProgress(position)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_pdf_reader)

        // 先绑定视图，保证后续任何提前 finish 时 onDestroy 访问安全。
        pager = findViewById(R.id.pdfPager)
        pageIndicator = findViewById(R.id.pdfPageIndicator)

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

        findViewById<Button>(R.id.pdfAddAnnotation).setOnClickListener { promptAnnotation() }

        val pdf = openRenderer(uri)
        if (pdf == null) {
            toast(getString(R.string.pdf_error_open))
            finish()
            return
        }
        renderer = pdf

        adapter = PdfPageAdapter(pdf, renderWidth())
        pager.adapter = adapter
        pager.registerOnPageChangeCallback(onPageChanged)

        val lastPage = (pdf.pageCount - 1).coerceAtLeast(0)
        val startPage = progressStore.load(docId)?.page?.coerceIn(0, lastPage) ?: 0
        pager.setCurrentItem(startPage, false)
        updateIndicator(pager.currentItem)
    }

    override fun onDestroy() {
        super.onDestroy()
        if (::pager.isInitialized) {
            pager.unregisterOnPageChangeCallback(onPageChanged)
        }
        adapter = null
        renderer?.close()
        fileDescriptor?.close()
        renderer = null
        fileDescriptor = null
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

    /** 渲染宽度取屏幕宽度，保证位图适配可见区域。 */
    private fun renderWidth(): Int {
        val width = resources.displayMetrics.widthPixels
        return if (width > 0) width else DEFAULT_RENDER_WIDTH
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
            .setTitle(getString(R.string.pdf_annotation_title, pager.currentItem + 1))
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
            location = "page:${pager.currentItem + 1}",
            text = text,
            createdAt = now,
            updatedAt = now,
        )
        annotationStore.add(annotation)
        toast(getString(R.string.pdf_annotation_saved, annotationStore.count(docId)))
    }

    private fun toast(message: String) {
        Toast.makeText(this, message, Toast.LENGTH_SHORT).show()
    }

    companion object {
        /** Intent 中携带 PDF Uri 的键。 */
        const val EXTRA_URI: String = "com.notes.app.reader.EXTRA_URI"

        /** 与 epub 侧共享同一 SharedPreferences 文件，但键命名空间不同。 */
        const val PREFS_NAME: String = "pdf_reader"

        private const val DEFAULT_RENDER_WIDTH = 1080

        /** 构造进入阅读器的 Intent。 */
        fun intent(context: Context, uri: Uri): Intent =
            Intent(context, PdfReaderActivity::class.java).putExtra(EXTRA_URI, uri)
    }
}
