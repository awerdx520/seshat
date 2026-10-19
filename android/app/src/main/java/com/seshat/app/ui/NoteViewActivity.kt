package com.seshat.app.ui

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import android.util.TypedValue
import android.view.Menu
import android.view.MenuItem
import android.view.View
import android.webkit.WebView
import android.widget.ProgressBar
import android.widget.Toast
import androidx.activity.result.contract.ActivityResultContracts
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.appbar.MaterialToolbar
import com.seshat.app.R
import com.seshat.app.notes.NoteFormat
import com.seshat.app.notes.NoteReader
import com.seshat.app.notes.NoteRef
import com.seshat.app.notes.NoteScanner
import com.seshat.app.notes.render.HtmlDocument
import com.seshat.app.notes.render.MarkdownHtmlRenderer
import com.seshat.app.notes.render.OrgHtmlRenderer
import java.io.File
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors

/**
 * 笔记阅读页（M10.7 T5）：把 org / markdown 渲染成 HTML，用 [WebView] 只读展示。
 *
 * 数据流：`EXTRA_PATH`（本地文件）或 `EXTRA_URI`（SAF 文档）二选一 → 后台 [NoteReader.read]
 * → 按格式选 [OrgHtmlRenderer] / [MarkdownHtmlRenderer] 产出片段 → [HtmlDocument.wrap]
 * 包成完整文档 → 主线程 `loadDataWithBaseURL(null, …)` 载入。
 *
 * 安全约束（**不得**放宽）：渲染器只产出静态 HTML，所以 JS / file:// / content:// /
 * DOM Storage 全部关闭，且不向页面注入任何 JS 桥接口；链接仅在
 * [com.seshat.app.notes.render.RenderSupport] 的 scheme 白名单内才会成为 `<a>`。
 *
 * 可写性：只有 [NoteRef.LocalFile] 提供「编辑源码」菜单项（[NoteEditActivity]），
 * SAF 文档只读（跨 provider 写入语义差异过大）。编辑返回 `RESULT_OK` 时原地重渲染，
 * 不重建 Activity，避免丢失滚动位置与缩放状态。
 *
 * @see intentForFile
 * @see intentForUri
 */
class NoteViewActivity : AppCompatActivity() {

    private lateinit var webView: WebView
    private lateinit var noteLoading: ProgressBar

    /** 当前笔记引用（菜单可见性判定 + 重渲染用）。 */
    private var ref: NoteRef? = null

    /** 当前笔记格式（重渲染时沿用，避免重复推导扩展名）。 */
    private var format: NoteFormat? = null

    /** toolbar 当前标题（初值来自 `EXTRA_TITLE`；重渲染后随新内容的首个 heading 更新）。 */
    private var currentTitle: String = ""

    /** 文件读取线程（所有 IO 都在后台执行）。 */
    private var executor: ExecutorService? = null

    /** 编辑源码返回：保存成功才重渲染（取消则保持原样）。 */
    private val editLauncher = registerForActivityResult(
        ActivityResultContracts.StartActivityForResult(),
    ) { result ->
        if (result.resultCode == Activity.RESULT_OK) reload()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContentView(R.layout.activity_note_view)

        webView = findViewById(R.id.noteWebView)
        noteLoading = findViewById(R.id.noteLoading)
        setSupportActionBar(findViewById<MaterialToolbar>(R.id.noteToolbar))

        // 目标非法时 resolveTarget 内部已 Toast + finish
        if (!resolveTarget()) return

        applySafeWebSettings()
        executor = Executors.newSingleThreadExecutor()
        reload()
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {
        menuInflater.inflate(R.menu.menu_note_view, menu)
        return true
    }

    override fun onPrepareOptionsMenu(menu: Menu): Boolean {
        // SAF 文档只读 → 隐藏「编辑源码」
        menu.findItem(R.id.action_edit_source)?.isVisible = ref is NoteRef.LocalFile
        return super.onPrepareOptionsMenu(menu)
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        if (item.itemId == R.id.action_edit_source) {
            val local = ref as? NoteRef.LocalFile ?: return false
            editLauncher.launch(NoteEditActivity.intent(this, local.file))
            return true
        }
        return super.onOptionsItemSelected(item)
    }

    override fun onDestroy() {
        super.onDestroy()
        executor?.shutdownNow()
        executor = null
        if (::webView.isInitialized) {
            webView.stopLoading()
            webView.destroy()
        }
    }

    // ---------------------------------------------------------------- 目标解析

    /**
     * 解析 intent 目标（`EXTRA_PATH` 优先于 `EXTRA_URI`）并确定格式。
     *
     * @return 目标合法返回 `true`；缺参数或格式不支持时已 Toast + [finish] 并返回 `false`。
     */
    private fun resolveTarget(): Boolean {
        val path = intent.getStringExtra(EXTRA_PATH)
        val uriString = intent.getStringExtra(EXTRA_URI)
        val target: NoteRef = when {
            !path.isNullOrEmpty() -> NoteRef.LocalFile(File(path))
            !uriString.isNullOrEmpty() -> NoteRef.SafDocument(Uri.parse(uriString))
            else -> {
                Toast.makeText(this, R.string.note_load_failed, Toast.LENGTH_LONG).show()
                finish()
                return false
            }
        }
        val extension = when (target) {
            is NoteRef.LocalFile -> target.file.extension
            is NoteRef.SafDocument -> documentExtension(target.uri)
        }
        val resolved = formatOf(extension)
        if (resolved == null) {
            Toast.makeText(this, R.string.note_unsupported_format, Toast.LENGTH_LONG).show()
            finish()
            return false
        }
        ref = target
        format = resolved
        currentTitle = intent.getStringExtra(EXTRA_TITLE)?.takeIf { it.isNotBlank() }
            ?: fallbackTitle(target)
        title = currentTitle
        return true
    }

    /** 扩展名 → 格式；不支持返回 `null`（`markdown` 视同 `md`）。 */
    private fun formatOf(extension: String): NoteFormat? = when (extension.lowercase()) {
        "org" -> NoteFormat.ORG
        "md", "markdown" -> NoteFormat.MARKDOWN
        else -> null
    }

    /**
     * SAF 文档的扩展名。
     *
     * 优先取 uri 的最后一个路径段（SAF 的 document uri 通常形如
     * `…/document/primary:notes/a.md`，末段带文件名）；取不到扩展名时退回查询
     * [OpenableColumns.DISPLAY_NAME]（部分 provider 的 document id 不是文件名）。
     */
    private fun documentExtension(uri: Uri): String {
        val segment = uri.lastPathSegment.orEmpty()
        val fromSegment = segment.substringAfterLast('.', "")
        if (fromSegment.isNotEmpty() && fromSegment != segment) return fromSegment
        return runCatching {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        cursor.getString(0)?.substringAfterLast('.', "").orEmpty()
                    } else {
                        ""
                    }
                }
                .orEmpty()
        }.getOrDefault("")
    }

    /** 无 `EXTRA_TITLE` 时的标题回退：本地文件名（去扩展名）/ SAF uri 末段。 */
    private fun fallbackTitle(target: NoteRef): String = when (target) {
        is NoteRef.LocalFile -> target.file.nameWithoutExtension
        is NoteRef.SafDocument -> target.uri.lastPathSegment?.substringAfterLast('/').orEmpty()
    }

    // ---------------------------------------------------------------- 渲染

    /** WebView 安全设置：一条都不许放宽（见类注释）。 */
    private fun applySafeWebSettings() {
        val settings = webView.settings
        settings.javaScriptEnabled = false
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.domStorageEnabled = false
        // 仅保留缩放手势（长文档阅读必需），缩放按钮不显示
        settings.setSupportZoom(true)
        settings.builtInZoomControls = true
        settings.displayZoomControls = false
        // 背景跟随主题：CSS 加载前/过度滚动时显示的是这个颜色，暗色主题下不能闪白
        webView.setBackgroundColor(themeBackgroundColor())
    }

    /** 从当前主题解析 `android:colorBackground`（Theme.Material3.DayNight 亮/暗两套）。 */
    private fun themeBackgroundColor(): Int {
        val value = TypedValue()
        return if (theme.resolveAttribute(android.R.attr.colorBackground, value, true)) {
            value.data
        } else {
            Color.WHITE
        }
    }

    /**
     * 重新读取并渲染当前笔记（首次加载与「编辑源码」保存返回共用）。
     *
     * 不重建 Activity：保留滚动位置、缩放比例与菜单状态。
     * 渲染成功后按**新内容**的首个 heading 同步 toolbar 标题（改标题后不再显示旧值；
     * 取不到 heading 时保留原标题，不置空）。
     */
    private fun reload() {
        val target = ref ?: return
        val noteFormat = format ?: return
        val work = executor ?: return
        if (work.isShutdown) return
        noteLoading.visibility = View.VISIBLE
        work.execute {
            val text = NoteReader.read(target, contentResolver)
            val html = text?.let { HtmlDocument.wrap(render(it, noteFormat)) }
            // 新内容的首个 heading 作为新标题；取不到（文件被清空/无 heading）时保持原值不置空
            val derived = text?.let { NoteScanner.firstHeading(it, noteFormat) }
            runOnUiThread {
                if (isFinishing || isDestroyed) return@runOnUiThread
                if (html == null) {
                    noteLoading.visibility = View.GONE
                    Toast.makeText(this, R.string.note_load_failed, Toast.LENGTH_LONG).show()
                    finish()
                    return@runOnUiThread
                }
                webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null)
                // 「编辑源码」保存后正文已重渲染，标题也必须跟着新内容走（否则停在打开时的旧标题）
                if (derived != null && derived != currentTitle) {
                    currentTitle = derived
                    title = derived
                }
                noteLoading.visibility = View.GONE
            }
        }
    }

    /** 按格式选渲染器（两者都只产出片段，外壳由 [HtmlDocument] 负责）。 */
    private fun render(text: String, noteFormat: NoteFormat): String = when (noteFormat) {
        NoteFormat.ORG -> OrgHtmlRenderer.render(text)
        NoteFormat.MARKDOWN -> MarkdownHtmlRenderer.render(text)
    }

    companion object {
        /** [NoteRef.LocalFile] 的绝对路径（String）。 */
        const val EXTRA_PATH = "extra_note_path"

        /** [NoteRef.SafDocument] 的 uri 字符串（String）。 */
        const val EXTRA_URI = "extra_note_uri"

        /** 标题栏文案（String，可选）。 */
        const val EXTRA_TITLE = "extra_note_title"

        /** 打开本地文件的阅读页。 */
        fun intentForFile(context: Context, file: File, title: String): Intent =
            Intent(context, NoteViewActivity::class.java)
                .putExtra(EXTRA_PATH, file.absolutePath)
                .putExtra(EXTRA_TITLE, title)

        /** 打开 SAF 文档的阅读页（只读，无「编辑源码」）。 */
        fun intentForUri(context: Context, uri: Uri, title: String): Intent =
            Intent(context, NoteViewActivity::class.java)
                .putExtra(EXTRA_URI, uri.toString())
                .putExtra(EXTRA_TITLE, title)
    }
}
