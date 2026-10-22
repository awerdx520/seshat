package com.seshat.app.reader

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.fragment.app.Fragment
import androidx.webkit.WebViewAssetLoader
import com.seshat.app.R
import com.seshat.app.settings.AppPreferences

/**
 * 单章阅读页：一个 WebView 承载一章 HTML。
 *
 * 页面由 [EpubReaderActivity] 提供（内存 zip 源 + 章节表），
 * 资源经 [EpubAssetHandler] 从同一份内存 zip 供给。
 *
 * 选区采集有两条路径（M10.3 T4）：
 * - [selectedText]：旧的纯文本路径，仅回传选中原文（旧调用方不改也能工作）；
 * - [selection]：新路径，额外回传章内字符偏移（见 [SelectionPayload]），供 EPUB location 使用。
 */
class ChapterFragment : Fragment() {

    /** 本章在 spine 中的序号（Activity 亦用它定位当前页）。 */
    var chapterIndex: Int = 0
        private set

    private var webView: WebView? = null
    private var pendingRestoreScroll: Int? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        chapterIndex = requireArguments().getInt(ARG_INDEX)
    }

    override fun onCreateView(
        inflater: LayoutInflater,
        container: ViewGroup?,
        savedInstanceState: Bundle?,
    ): View = inflater.inflate(R.layout.fragment_chapter, container, false)

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        super.onViewCreated(view, savedInstanceState)
        val host = activity as? EpubReaderActivity ?: return
        val source = host.epubSource ?: return

        val web = view.findViewById<WebView>(R.id.chapterWebView)
        webView = web
        with(web.settings) {
            javaScriptEnabled = true // 取选区文本需要 JS
            allowFileAccess = false // 资源走 https 虚拟域，不开放 file://
            allowContentAccess = false
            builtInZoomControls = true
            displayZoomControls = false
            // 正文字号（设置页配置，打开阅读器时生效）
            textZoom = AppPreferences.open(requireContext()).textZoom()
        }
        web.isVerticalScrollBarEnabled = false
        web.setOnScrollChangeListener { _, _, scrollY, _, _ -> host.onChapterScrolled(chapterIndex, scrollY) }

        val loader = WebViewAssetLoader.Builder()
            .setDomain(EPUB_ASSET_DOMAIN)
            .addPathHandler(EPUB_ASSET_PATH, EpubAssetHandler(source))
            .build()
        web.webViewClient = EpubWebViewClient(loader) { view0, _ ->
            pendingRestoreScroll?.let { y ->
                view0.scrollTo(0, y)
                pendingRestoreScroll = null
            }
        }

        val chapter = host.chapterAt(chapterIndex)
        val html = chapter?.let { host.readChapterHtml(it) }
        if (chapter == null || html == null) {
            web.loadDataWithBaseURL(
                null,
                "<html><body>${getString(R.string.reader_chapter_missing)}</body></html>",
                "text/html",
                "UTF-8",
                null,
            )
            return
        }
        pendingRestoreScroll = host.savedScrollY(chapterIndex)
        web.loadDataWithBaseURL(chapterBaseUrl(chapter.href), html, "text/html", "UTF-8", null)
    }

    /** 上报当前滚动位置（离开视野前保证进度不丢）。 */
    override fun onPause() {
        (activity as? EpubReaderActivity)?.onChapterScrolled(chapterIndex, webView?.scrollY ?: 0)
        super.onPause()
    }

    override fun onDestroyView() {
        (activity as? EpubReaderActivity)?.onChapterScrolled(chapterIndex, webView?.scrollY ?: 0)
        (webView?.parent as? ViewGroup)?.removeView(webView)
        webView?.destroy()
        webView = null
        super.onDestroyView()
    }

    /**
     * 读取 WebView 中当前选中的文本（无选区时回调空串）。
     *
     * 保留的原路径：只取纯文本，**不涉及偏移**。旧调用方无需改动即可继续工作；
     * 需要偏移（EPUB location）时用 [selection]。
     */
    fun selectedText(callback: (String) -> Unit) {
        val web = webView
        if (web == null) {
            callback("")
            return
        }
        web.evaluateJavascript(LEGACY_SELECTION_SCRIPT) { result ->
            callback(decodeJsString(result))
        }
    }

    /**
     * 读取选区：回调（纯文本, 章内偏移）。
     *
     * 偏移为 `null` 表示取不到（旧 WebView / 脚本失败 / 空选区），调用方应按旧行为降级
     * （location 退回 `chapter-<chapterIndex>`）；此时纯文本仍然可用，不会比 [selectedText] 更差。
     */
    fun selection(callback: (text: String, range: SelectionRange?) -> Unit) {
        val web = webView
        if (web == null) {
            callback("", null)
            return
        }
        readSelection(web, callback)
    }

    companion object {
        private const val ARG_INDEX = "chapter_index"

        fun newInstance(chapterIndex: Int): ChapterFragment = ChapterFragment().apply {
            arguments = Bundle().apply { putInt(ARG_INDEX, chapterIndex) }
        }
    }
}

/**
 * 旧脚本：只返回纯文本。
 *
 * 保留为**回退路径**（旧 WebView / 新脚本取不到偏移时），保证既有「取选中文本」行为不回退。
 */
private const val LEGACY_SELECTION_SCRIPT = "(function(){return String(window.getSelection());})()"

/**
 * 读取 WebView 选区：优先新脚本（带章内偏移），失败时回退旧脚本（仅纯文本）。
 *
 * 抽成文件级函数而非 [ChapterFragment] 成员，是因为竖向连续滚动模式下章节由
 * `ChapterScrollAdapter` 的 ViewHolder 直接持有 WebView，没有 Fragment 可调用。
 *
 * @param callback 参数为（纯文本, 偏移）；偏移 `null` 表示取不到（调用方按旧行为降级）
 */
internal fun readSelection(web: WebView, callback: (text: String, range: SelectionRange?) -> Unit) {
    web.evaluateJavascript(SelectionPayload.SCRIPT) { raw ->
        val range = SelectionPayload.parse(raw)
        if (range != null) {
            callback(range.text, range)
        } else {
            // 空选区也会走到这里（新脚本返回空串）：多一次 JS 往返换来「旧行为零差异」，
            // 因为旧脚本把「空选区」与「取不到偏移」都表现为空文本，调用方的提示文案不变。
            web.evaluateJavascript(LEGACY_SELECTION_SCRIPT) { legacy ->
                callback(decodeJsString(legacy), null)
            }
        }
    }
}

/** evaluateJavascript 返回的是 JSON 字面量，这里还原为普通字符串（MVP 只处理常见转义）。 */
internal fun decodeJsString(raw: String?): String {
    if (raw == null || raw == "null") return ""
    var text = raw.trim()
    if (text.length >= 2 && text.startsWith('"') && text.endsWith('"')) {
        text = text.substring(1, text.length - 1)
    }
    return text
        .replace("\\r\\n", "\n")
        .replace("\\n", "\n")
        .replace("\\r", "\r")
        .replace("\\t", "\t")
        .replace("\\\"", "\"")
        .replace("\\/", "/")
        .replace("\\\\", "\\")
}
