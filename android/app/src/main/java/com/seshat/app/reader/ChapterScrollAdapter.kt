package com.seshat.app.reader

import android.view.ViewGroup
import android.webkit.WebView
import androidx.recyclerview.widget.RecyclerView
import androidx.webkit.WebViewAssetLoader
import com.seshat.app.R

/** 竖向滚动模式下的章节数据源与回调。 */
interface ChapterScrollHost {
    /** 章节总数。 */
    fun chapterCount(): Int

    /** 第 [index] 章的元信息。 */
    fun chapterAt(index: Int): EpubChapter?

    /** 读取第 [index] 章的 HTML（内存 zip 读取）。 */
    fun readChapterHtml(chapter: EpubChapter): String?

    /** 某章内容高度测量完成（用于重锚）。 */
    fun onChapterMeasured(position: Int)
}

/**
 * 竖向连续滚动模式的章节适配器（M9.2）：每章一个 [WebView]，首尾相接纵向排列。
 *
 * 三个关键设计取舍：
 * 1. **禁用复用**：View 复用会把同一个 WebView 绑到别的章节上，一旦发生
 *    `loadDataWithBaseURL` 重载就会丢失该章已加载的文档与滚动锚点（WebView 内容不可
 *    低成本快照）。因此每章分配唯一 `viewType`（`getItemViewType = position`），
 *    配合宿主把各级复用池上限设为 0，实现「一章一实例」。代价是内存随可见章节数增长，
 *    但 RecyclerView 仍只保留视口附近若干章（视口外实例被回收销毁），可接受。
 * 2. **高度用 JS 量**：RecyclerView 需要每项的确切高度才能正确布局与滚动；HTML 内容是
 *    流式排版，原生侧无法预知排版高度，只能在页面加载完成后一次 JS 取回
 *    `scrollHeight`（内容 CSS 高）与 `window.innerHeight`（视口 CSS 高），按
 *    「视口物理高 / 视口 CSS 高」求出每 CSS 像素对应的物理像素数，再换算为物理像素写回
 *    LayoutParams，让相邻章节首尾相接。**不乘 `displayMetrics.density`**：epub 章节 HTML
 *    通常没有 `viewport` meta，WebView 会按约 980 CSS px 布局再缩放适配屏宽，此时密度系数
 *    与实际缩放比不一致，会高估内容高度（章末多余空白、恢复位置偏高）；用视口比值则对
 *    「有/无 viewport meta」都成立。
 * 3. **禁用 WebView 自身滚动**（`isNestedScrollingEnabled = false` + 高度等于内容高度）：
 *    滚动统一交给外层 RecyclerView，避免「WebView 内滚动 / 外层滚动」两套滚动体系嵌套抢占
 *    触摸手势，出现滚动抖动或滚不动的问题。
 *
 * @param host        章节数据源与回调（由 Activity 实现，避免本类直接依赖 Activity）。
 * @param assetLoader 已绑定 epub 内存 zip 的资源加载器（Activity 构造并复用同一份源）。
 * @param textZoom    正文字号百分比（[com.seshat.app.settings.AppPreferences.textZoom]）。
 */
class ChapterScrollAdapter(
    private val host: ChapterScrollHost,
    private val assetLoader: WebViewAssetLoader,
    private val textZoom: Int,
) : RecyclerView.Adapter<ChapterScrollAdapter.ChapterHolder>() {

    /** 单章视图：[loadedPosition] 记录该 WebView 当前承载的章节（-1 表示未加载）。 */
    class ChapterHolder(val webView: WebView, var loadedPosition: Int = -1) :
        RecyclerView.ViewHolder(webView)

    override fun getItemCount(): Int = host.chapterCount()

    /** 每章唯一 viewType：配合复用池上限 0，从根本上禁止跨章复用 WebView。 */
    override fun getItemViewType(position: Int): Int = position

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): ChapterHolder {
        val context = parent.context
        val web = WebView(context)
        web.layoutParams = RecyclerView.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            // 测量前用屏高占位，避免 item 高度为 0 导致 RecyclerView 抖动
            context.resources.displayMetrics.heightPixels,
        )
        web.isNestedScrollingEnabled = false
        with(web.settings) {
            javaScriptEnabled = true // 取选区文本与测量内容高度需要 JS
            allowFileAccess = false // 资源走 https 虚拟域，不开放 file://
            allowContentAccess = false
            builtInZoomControls = true
            displayZoomControls = false
            textZoom = this@ChapterScrollAdapter.textZoom
        }
        web.isVerticalScrollBarEnabled = false
        return ChapterHolder(web)
    }

    override fun onBindViewHolder(holder: ChapterHolder, position: Int) {
        // 同一实例已承载该章：无需重载（重载会丢滚动锚点与已加载文档）。
        if (holder.loadedPosition == position) return
        val chapter = host.chapterAt(position) ?: return
        holder.loadedPosition = position
        val html = host.readChapterHtml(chapter)

        holder.webView.webViewClient = EpubWebViewClient(assetLoader) measure@{ view, _ ->
            // 实例已被挪给别的章节时丢弃本次测量结果（正常情况下禁用复用后不会发生）。
            if (holder.loadedPosition != position) return@measure
            // 页面加载完成：一次 JS 同时取内容 CSS 高与视口 CSS 高
            view.evaluateJavascript(
                "(function(){var d=document.documentElement;" +
                    "return d.scrollHeight + '/' + (window.innerHeight || 1);})()",
            ) { raw ->
                if (holder.loadedPosition != position) return@evaluateJavascript
                val parts = raw?.trim()?.trim('"')?.split('/') ?: return@evaluateJavascript
                val cssHeight = parts.getOrNull(0)?.toFloatOrNull() ?: return@evaluateJavascript
                val cssViewport = parts.getOrNull(1)?.toFloatOrNull()?.takeIf { it > 0f }
                    ?: return@evaluateJavascript
                // 视口物理高度 / 视口 CSS 高度 = 每个 CSS 像素对应的物理像素数
                // （与是否注入 viewport meta 无关，避免 scrollHeight × density 的高估）
                val pxPerCss = view.height.toFloat().coerceAtLeast(1f) / cssViewport
                val px = (cssHeight * pxPerCss).toInt().coerceAtLeast(1)
                if (view.layoutParams.height != px) {
                    view.layoutParams = view.layoutParams.also { it.height = px }
                    view.requestLayout()
                    host.onChapterMeasured(position)
                }
            }
        }
        val baseUrl = chapterBaseUrl(chapter.href)
        if (html != null) {
            holder.webView.loadDataWithBaseURL(baseUrl, html, "text/html", "UTF-8", null)
        } else {
            holder.webView.loadDataWithBaseURL(
                null,
                "<html><body>${holder.webView.context.getString(R.string.reader_chapter_missing)}</body></html>",
                "text/html",
                "UTF-8",
                null,
            )
        }
    }

    override fun onViewRecycled(holder: ChapterHolder) {
        super.onViewRecycled(holder)
        // 销毁 WebView，释放其渲染进程侧资源；同时清标记，避免实例被误当成「已加载」。
        holder.loadedPosition = -1
        holder.webView.stopLoading()
        (holder.webView.parent as? ViewGroup)?.removeView(holder.webView)
        // 回收发生在布局/动画过程中，立即 destroy 会遇到「destroyed WebView 仍被调用」；
        // post 到当前帧结束后再销毁
        holder.webView.post { runCatching { holder.webView.destroy() } }
    }

    /** 取 [position] 章当前的 [WebView]（未附着到视口时返回 `null`）。 */
    fun webViewAt(recycler: RecyclerView, position: Int): WebView? =
        (recycler.findViewHolderForAdapterPosition(position) as? ChapterHolder)?.webView
}
