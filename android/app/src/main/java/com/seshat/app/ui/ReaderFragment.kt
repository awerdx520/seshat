package com.seshat.app.ui

import android.net.Uri
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.fragment.app.Fragment
import com.google.android.material.button.MaterialButton
import com.seshat.app.R
import com.seshat.app.importer.BookImporter
import com.seshat.app.reader.EpubReaderActivity
import com.seshat.app.reader.PdfReaderActivity
import java.io.File

/**
 * 阅读 tab（M9.1 阶段承载既有 4 个阅读入口）。
 *
 * 示例 EPUB / 选择 EPUB / 选择 PDF / 导入书籍——均由原 `MainActivity` 迁入，
 * 行为不变。书架（元数据来自服务端、按需下载）由 M10.1 接入。
 */
class ReaderFragment : Fragment() {

    /** 系统文档选择器：选择 epub 后进入 [EpubReaderActivity]。 */
    private val pickEpub =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri != null) {
                startActivity(EpubReaderActivity.intentForUri(requireContext(), uri))
            }
        }

    /** 系统文档选择器：选择 pdf 后进入 [PdfReaderActivity]。 */
    private val pickPdf =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri != null) {
                startActivity(PdfReaderActivity.intent(requireContext(), uri))
            }
        }

    /** 系统文档选择器：经 [BookImporter] 导入书籍到应用私有阅读库。 */
    private val pickImport =
        registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri: Uri? ->
            if (uri == null) return@registerForActivityResult
            val result = BookImporter(requireContext()).import(uri)
            Toast.makeText(requireContext(), result.message, Toast.LENGTH_LONG).show()
        }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_reader, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        view.findViewById<MaterialButton>(R.id.openSampleButton).setOnClickListener {
            openSampleEpub()
        }
        view.findViewById<MaterialButton>(R.id.pickEpubButton).setOnClickListener {
            // 部分文档提供方不返回 epub 专用 MIME，放开为任意类型以免选不到文件。
            pickEpub.launch(arrayOf("*/*"))
        }
        view.findViewById<MaterialButton>(R.id.openPdfButton).setOnClickListener {
            pickPdf.launch(arrayOf("application/pdf"))
        }
        view.findViewById<MaterialButton>(R.id.importButton).setOnClickListener {
            pickImport.launch(arrayOf("*/*"))
        }
    }

    /** 把 assets/sample.epub 复制到 filesDir（首次）后打开，保证无外部文件也能验证阅读链路。 */
    private fun openSampleEpub() {
        val context = requireContext()
        val target = File(context.filesDir, SAMPLE_ASSET)
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
        }
        startActivity(EpubReaderActivity.intentForFile(context, target))
    }

    private companion object {
        const val SAMPLE_ASSET = "sample.epub"
    }
}
