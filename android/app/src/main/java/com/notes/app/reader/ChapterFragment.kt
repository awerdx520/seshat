package com.notes.app.reader

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.webkit.WebView
import androidx.fragment.app.Fragment
import androidx.webkit.WebViewAssetLoader
import com.notes.app.R

/**
 * 单章阅读页：一个 WebView 承载一章 HTML。
 *
 * 页面由 [EpubReaderActivity] 提供（内存 zip 源 + 章节表），
 * 资源经 [EpubAssetHandler] 从同一份内存 zip 供给。
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

    /** 读取 WebView 中当前选中的文本（无选区时回调空串）。 */
    fun selectedText(callback: (String) -> Unit) {
        val web = webView
        if (web == null) {
            callback("")
            return
        }
        web.evaluateJavascript("(function(){return String(window.getSelection());})()") { result ->
            callback(decodeJsString(result))
        }
    }

    companion object {
        private const val ARG_INDEX = "chapter_index"

        fun newInstance(chapterIndex: Int): ChapterFragment = ChapterFragment().apply {
            arguments = Bundle().apply { putInt(ARG_INDEX, chapterIndex) }
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
