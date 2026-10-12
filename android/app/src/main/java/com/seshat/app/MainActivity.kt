package com.seshat.app

import android.os.Bundle
import android.widget.Button
import android.widget.TextView
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.seshat.app.gtd.GtdActivity
import com.seshat.app.importer.BookImporter
import com.seshat.app.reader.EpubReaderActivity
import com.seshat.app.reader.PdfReaderActivity
import java.io.File

/**
 * 应用入口 Activity（M3.1 骨架 + M3.2 epub 阅读入口 + M3.3 pdf 入口 + M3.5 图书导入）。
 *
 * 入口：打开内置示例 epub（assets/sample.epub）、用系统文件选择器打开任意 epub、
 * 选择 pdf 文件进入 [PdfReaderActivity]，或经 [BookImporter] 导入书籍到应用私有阅读库。
 * 后续 M4 在此接入 GTD 双 Tab。
 */
class MainActivity : AppCompatActivity() {

    private val pickEpub = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) startActivity(EpubReaderActivity.intentForUri(this, uri))
    }

    /** 系统文档选择器：选择 pdf 后进入 [PdfReaderActivity]。 */
    private val pickPdf = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) startActivity(PdfReaderActivity.intent(this, uri))
    }

    /** 系统文档选择器：经 [BookImporter] 导入所选书籍到应用私有阅读库，并提示导入结果。 */
    private val pickImport = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) {
            val result = BookImporter(this).import(uri)
            Toast.makeText(this, result.message, Toast.LENGTH_LONG).show()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_main)

        val hello = findViewById<TextView>(R.id.helloText)
        hello.text = getString(R.string.app_name)

        findViewById<Button>(R.id.openSampleButton).setOnClickListener { openSampleEpub() }
        findViewById<Button>(R.id.pickEpubButton).setOnClickListener {
            // 部分文档提供方不返回 epub 专用 MIME，放开为任意类型以免选不到文件
            pickEpub.launch(arrayOf("*/*"))
        }
        findViewById<Button>(R.id.openPdfButton).setOnClickListener {
            pickPdf.launch(arrayOf("application/pdf"))
        }
        findViewById<Button>(R.id.importButton).setOnClickListener {
            pickImport.launch(arrayOf("*/*"))
        }
        findViewById<Button>(R.id.openGtdButton).setOnClickListener {
            startActivity(GtdActivity.intent(this))
        }
    }

    /** 把 assets/sample.epub 复制到 filesDir（首次）后打开，保证无外部文件也能验证阅读链路。 */
    private fun openSampleEpub() {
        val target = File(filesDir, SAMPLE_ASSET)
        if (!target.exists() || target.length() == 0L) {
            try {
                assets.open(SAMPLE_ASSET).use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
            } catch (e: Exception) {
                Toast.makeText(
                    this,
                    getString(R.string.reader_open_failed, e.message ?: SAMPLE_ASSET),
                    Toast.LENGTH_LONG,
                ).show()
                return
            }
        }
        startActivity(EpubReaderActivity.intentForFile(this, target))
    }

    private companion object {
        const val SAMPLE_ASSET = "sample.epub"
    }
}
