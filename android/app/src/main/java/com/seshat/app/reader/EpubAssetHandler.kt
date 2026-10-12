package com.seshat.app.reader

import android.net.Uri
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import androidx.webkit.WebViewAssetLoader
import androidx.webkit.WebViewClientCompat
import java.io.ByteArrayInputStream
import java.net.URI

/** 虚拟域路径前缀：epub 内资源统一挂在 `/epub/` 下。 */
const val EPUB_ASSET_PATH = "/epub/"

/** 虚拟域（WebViewAssetLoader 默认域），以 https 提供本地资源，规避 file:// 访问限制。 */
const val EPUB_ASSET_DOMAIN = "appassets.androidplatform.net"

/** 章节 HTML 的 base URL 前缀。 */
const val EPUB_BASE_URL = "https://$EPUB_ASSET_DOMAIN$EPUB_ASSET_PATH"

/**
 * 把内存 zip 中的 epub 资源（图片/CSS/字体）喂给 WebView。
 *
 * [WebViewAssetLoader.PathHandler] 的回调发生在 WebView 的 IO 线程，
 * 这里只做只读的内存映射查找（[EpubSource] 构造后不可变），因此无需额外同步。
 */
class EpubAssetHandler(private val source: EpubSource) : WebViewAssetLoader.PathHandler {
    override fun handle(path: String): WebResourceResponse? {
        val name = path.trimStart('/')
        val bytes = source.read(name) ?: return null
        return WebResourceResponse(
            mimeTypeOf(name),
            null,
            200,
            "OK",
            emptyMap(),
            ByteArrayInputStream(bytes),
        )
    }
}

/** WebView 客户端：拦截虚拟域请求交给 [EpubAssetHandler]，并透出页面加载完成回调。 */
class EpubWebViewClient(
    private val assetLoader: WebViewAssetLoader,
    private val onPageFinished: ((WebView, String) -> Unit)? = null,
) : WebViewClientCompat() {

    override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest): WebResourceResponse? =
        assetLoader.shouldInterceptRequest(request.url)

    @Suppress("OVERRIDE_DEPRECATION")
    override fun shouldInterceptRequest(view: WebView, url: String): WebResourceResponse? =
        assetLoader.shouldInterceptRequest(Uri.parse(url))

    override fun onPageFinished(view: WebView, url: String) {
        super.onPageFinished(view, url)
        onPageFinished?.invoke(view, url)
    }
}

/**
 * 章节 HTML 的 base URL：指向该章节文件自身，使 HTML 内的相对资源引用
 * （`<img src="images/a.png">`、`<link href="../css/x.css">`）按章节目录自动解析。
 */
fun chapterBaseUrl(chapterHref: String): String = EPUB_BASE_URL + encodePath(chapterHref)

/** 按扩展名推断 MIME；未知类型按二进制流。 */
fun mimeTypeOf(path: String): String = when (path.substringAfterLast('.', "").lowercase()) {
    "xhtml", "html", "htm" -> "text/html"
    "css" -> "text/css"
    "js" -> "application/javascript"
    "png" -> "image/png"
    "jpg", "jpeg" -> "image/jpeg"
    "gif" -> "image/gif"
    "svg" -> "image/svg+xml"
    "webp" -> "image/webp"
    "ttf" -> "font/ttf"
    "otf" -> "font/otf"
    "woff" -> "font/woff"
    "woff2" -> "font/woff2"
    "xml", "ncx" -> "application/xml"
    "json" -> "application/json"
    else -> "application/octet-stream"
}

/** 对路径做最小百分号编码（保留 `/`），使带空格/中文的 href 也能作为 URL 使用。 */
internal fun encodePath(path: String): String = try {
    URI(null, null, "/$path", null).rawPath.removePrefix("/")
} catch (_: Exception) {
    path
}
