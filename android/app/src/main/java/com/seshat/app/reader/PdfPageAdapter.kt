package com.seshat.app.reader

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.LruCache
import android.view.ViewGroup
import android.widget.FrameLayout
import android.widget.ImageView
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.seshat.app.settings.ReaderPageMode
import java.lang.ref.WeakReference
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import kotlin.math.roundToInt

/** PDF 手写层的宿主回调（由 Activity 实现）。 */
interface PdfInkHost {
    /** 该页已有的笔迹。 */
    fun inkStrokes(page: Int): List<InkStroke>

    /** 一笔完成，宿主负责持久化。 */
    fun onInkStrokeFinished(page: Int, stroke: InkStroke)

    /** 当前是否处于手写模式。 */
    fun isInkEnabled(): Boolean
}

/**
 * 未接入手写层时的空实现：手写层相关调用全部退化为无操作。
 *
 * 用途：T3 之前 Activity 尚未实现 [PdfInkHost]，构造函数以该默认值兜底，
 * 保证 Adapter 可独立编译与运行（此时手写层不响应触摸、无笔迹）。
 */
private object NoOpPdfInkHost : PdfInkHost {
    override fun inkStrokes(page: Int): List<InkStroke> = emptyList()

    override fun onInkStrokeFinished(page: Int, stroke: InkStroke) = Unit

    override fun isInkEnabled(): Boolean = false
}

/**
 * PDF 页面适配器：把 [PdfRenderer] 的每一页渲染为 [Bitmap]，显示在 [ImageView] 上。
 *
 * 支持两种翻页模式（[ReaderPageMode]，由设置页决定，只在打开阅读器时生效）：
 * - [ReaderPageMode.HORIZONTAL]：由 `ViewPager2`/`PagerSnapHelper` 管理的整页横滑，
 *   每页填满视口，故 LayoutParams 为 `MATCH_PARENT × MATCH_PARENT` + `FIT_CENTER`。
 * - [ReaderPageMode.VERTICAL]：竖向连续滚动，页与页首尾相接，
 *   故高度必须按页面纵横比给出真实值（`WRAP_CONTENT` + 预读页高），否则每页都是满屏高。
 *
 * 渲染方案要点：
 * - **为什么必须单线程**：[PdfRenderer] 非线程安全（同一时刻只允许打开一个
 *   [PdfRenderer.Page]），所有 `openPage`/`render` 必须串行执行，因此使用
 *   单线程 [renderExecutor]；渲染结果再 via [mainHandler] 回到主线程写回 View。
 * - **LRU 缓存**：位图占内存大，缓存上限取堆内存的 1/8，超出后按最近最少使用淘汰。
 * - **页高预读**：进页面时先在渲染线程遍历所有页算出「按渲染宽度缩放后的高度」，
 *   竖向模式下绑定即可给出正确高度，避免滚动时高度跳变。
 * - **白底**：PDF 页面背景透明，item 根 [FrameLayout] 铺白底，避免深色主题下黑字不可读。
 * - **手写层**：item 结构为「[FrameLayout] → [ImageView] + [InkOverlayView]」，
 *   LayoutParams 与竖向页高写回都挂在 item 根（`itemView`）上；写在子 ImageView 上无效。
 *
 * @param renderer   已打开的 [PdfRenderer]（生命周期由 Activity 管理，本类不负责关闭）。
 * @param renderWidth 目标渲染宽度（像素），高度按页面纵横比换算。
 * @param mode        翻页模式，决定子项 LayoutParams 与绑定策略。
 * @param defaultItemHeight 竖向模式的初始占位高度（像素，通常是屏高）；<=0 时取屏幕高度。
 * @param inkHost     手写层宿主回调；缺省为空实现（不绘制、不采样笔迹）。
 */
class PdfPageAdapter(
    private val renderer: PdfRenderer,
    private val renderWidth: Int,
    private val mode: ReaderPageMode,
    private val defaultItemHeight: Int = 0,
    private val inkHost: PdfInkHost = NoOpPdfInkHost,
) : RecyclerView.Adapter<PdfPageAdapter.PageViewHolder>() {

    /** 单页视图：白底 [FrameLayout] + 页面 [ImageView] + 手写覆盖层 [InkOverlayView]。 */
    class PageViewHolder(
        val container: FrameLayout,
        val imageView: ImageView,
        val overlay: InkOverlayView,
    ) : RecyclerView.ViewHolder(container)

    /** 渲染线程：`pdf-render`（守护性质由进程生命周期决定，随 Adapter shutdown 结束）。 */
    private val renderExecutor = Executors.newSingleThreadExecutor { r -> Thread(r, "pdf-render") }

    /** 渲染结果回到主线程写回 View 的通道。 */
    private val mainHandler = Handler(Looper.getMainLooper())

    /** 页位图 LRU 缓存，容量按堆内存 1/8 计。 */
    private val cache = object : LruCache<Int, Bitmap>(cacheSizeBytes()) {
        override fun sizeOf(key: Int, value: Bitmap): Int = value.byteCount
    }

    /** 每页在 [renderWidth] 下的像素高度；0 表示尚未算出。 */
    private val pageHeights = IntArray(renderer.pageCount)

    /** 宿主 RecyclerView 的弱引用，用于按可见项刷新手写层（Adapter 自身拿不到 RecyclerView）。 */
    private var recyclerViewRef: WeakReference<RecyclerView>? = null

    /** 手写模式开关的本地副本：绑定新出现的 item 时作为 [PdfInkHost] 的兜底。 */
    private var inkEnabled: Boolean = false

    /** 竖向模式的占位高度解析结果（懒计算，onCreateViewHolder 首次绑定时确定）。 */
    private var resolvedDefaultHeight: Int = 0

    init {
        runOnRender {
            computeHeights()
            // 页高算完后通知重建/重绑，让竖向模式拿到真实高度。
            mainHandler.post { notifyDataSetChanged() }
        }
    }

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PageViewHolder {
        val context = parent.context
        // 竖向占位高度：页高尚未算好时用它撑住 item，避免高度塌陷为 0。
        val placeholderHeight = resolveDefaultHeight(context)

        val frame = FrameLayout(context).apply {
            // 白底：PDF 页面背景透明，先铺白再渲染。
            setBackgroundColor(Color.WHITE)
            layoutParams = if (mode == ReaderPageMode.VERTICAL) {
                // 连续滚动：高度由页面纵横比决定，先用占位高度，绑定时再写成真实页高。
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    placeholderHeight,
                )
            } else {
                // 整页横滑：每页撑满视口，由 FIT_CENTER 缩放。
                ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
            }
        }

        val image = ImageView(context).apply {
            scaleType = ImageView.ScaleType.FIT_CENTER
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        val overlay = InkOverlayView(context).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
        }

        frame.addView(image)
        frame.addView(overlay)
        return PageViewHolder(frame, image, overlay)
    }

    override fun getItemCount(): Int = renderer.pageCount

    override fun onBindViewHolder(holder: PageViewHolder, position: Int) {
        // 手写层：每次绑定都设置，且放在所有 return 之前——否则命中位图缓存的页会没有笔迹。
        // 图片尺寸用「渲染宽度 + 该页渲染高度」推算，不依赖异步才就绪的 bitmap。
        // 页高尚未算出时传 0：InkOverlayView 会跳过绘制与采样，避免用「屏高」当页高
        // 造成 FIT_CENTER 比例失真 → 错误归一化坐标被持久化
        val pageHeight = pageHeights[position]
        if (pageHeight > 0) {
            holder.overlay.setImageSize(renderWidth, pageHeight)
        } else {
            holder.overlay.setImageSize(0, 0)
        }
        holder.overlay.setStrokes(inkHost.inkStrokes(position))
        // 宿主状态优先；本地开关用于适配「宿主尚未回调」的过渡窗口。
        holder.overlay.setInkEnabled(inkHost.isInkEnabled() || inkEnabled)
        holder.overlay.onStrokeFinished = { stroke -> inkHost.onInkStrokeFinished(position, stroke) }

        if (holder.bindingAdapterPosition == RecyclerView.NO_POSITION) {
            // 绑定期间位置不可用：不渲染（无法判断写回目标）。保留一条告警，
            // 该分支一旦命中会让本页停在白底状态，需据此排查。
            Log.w(TAG, "bind pos=$position 跳过渲染：bindingAdapterPosition=NO_POSITION")
            return
        }

        // 竖向模式：把真实页高写回 item 根（FrameLayout），使连续滚动的内容高度稳定。
        // 注意：写在子 ImageView 上无效——子 View 是 MATCH_PARENT，item 高度由根决定。
        if (mode == ReaderPageMode.VERTICAL && pageHeights[position] > 0) {
            val params = holder.container.layoutParams
            if (params.height != pageHeights[position]) {
                params.height = pageHeights[position]
                holder.container.layoutParams = params
                holder.container.requestLayout()
            }
        }

        // 缓存命中：直接显示，无需再渲染。
        val cached = cache.get(position)
        if (cached != null) {
            holder.imageView.setImageBitmap(cached)
            return
        }

        // 未命中：先清图（item 白底留作占位），再提交后台渲染。
        holder.imageView.setImageDrawable(null)
        runOnRender {
            // 先查缓存：滚动中同一页可能被重复提交，已有位图时**省掉渲染**。
            //
            // 注意「省渲染」不等于「省写回」：本方法进入前已把 ImageView 清空，
            // 而缓存的生产者 [preload] 只把位图放进缓存、明确不触碰任何 ViewHolder
            // （见其 KDoc）。若此处缓存命中就直接 return，没有任何人再把位图交给
            // ImageView —— 该页会永久停在「item 白底 + 仅手写层可见」的空白状态，
            // 直到某次重新绑定恰好命中缓存为止。
            //
            // 触发条件：bind 提交的渲染任务排在 preload 的渲染任务之后执行，
            // 且 preload 已经把同一页渲染进缓存（恢复进度直接落在末页时 preload
            // 覆盖 `lastPage-2..lastPage`，与首绑同帧，命中率最高）。
            val bitmap = cache.get(position)
                ?: renderPage(position)?.also { cache.put(position, it) }
                ?: return@runOnRender
            mainHandler.post {
                // 复用校验：位置已变则不写回（ViewHolder 可能已被复用给别的页）。
                if (holder.bindingAdapterPosition == position) {
                    holder.imageView.setImageBitmap(bitmap)
                } else {
                    Log.w(
                        TAG,
                        "render pos=$position 丢弃写回：bindingAdapterPosition=" +
                            "${holder.bindingAdapterPosition}",
                    )
                }
            }
        }
    }

    /** 缓存 RecyclerView 引用，供 [setInkEnabled] / [refreshInk] 定位可见项。 */
    override fun onAttachedToRecyclerView(recyclerView: RecyclerView) {
        super.onAttachedToRecyclerView(recyclerView)
        recyclerViewRef = WeakReference(recyclerView)
    }

    override fun onDetachedFromRecyclerView(recyclerView: RecyclerView) {
        super.onDetachedFromRecyclerView(recyclerView)
        recyclerViewRef = null
    }

    /** 切换手写模式：只刷新当前可见项的 overlay，避免整列表重绑导致图片闪烁。 */
    fun setInkEnabled(enabled: Boolean) {
        inkEnabled = enabled
        visibleHolders().forEach { it.overlay.setInkEnabled(enabled) }
    }

    /** 重新读取某页笔迹并刷新可见 holder（撤销/清除后调用）。 */
    fun refreshInk(page: Int) {
        visibleHolders()
            .filter { it.bindingAdapterPosition == page }
            .forEach { it.overlay.setStrokes(inkHost.inkStrokes(page)) }
    }

    /** 当前可见范围内的 ViewHolder。 */
    private fun visibleHolders(): List<PageViewHolder> {
        val rv = recyclerViewRef?.get() ?: return emptyList()
        val lm = rv.layoutManager as? LinearLayoutManager ?: return emptyList()
        val first = lm.findFirstVisibleItemPosition()
        val last = lm.findLastVisibleItemPosition()
        if (first == RecyclerView.NO_POSITION || last == RecyclerView.NO_POSITION) return emptyList()
        return (first..last).mapNotNull { position ->
            rv.findViewHolderForAdapterPosition(position) as? PageViewHolder
        }
    }

    /**
     * 预取 [center] 附近 ±2 页：只渲染并入缓存，不触碰任何 ViewHolder。
     *
     * 用于滚动停止/切页后提前准备邻近页，减少下一次滚动的白屏时间。
     */
    fun preload(center: Int) {
        val last = renderer.pageCount - 1
        for (index in (center - 2)..(center + 2)) {
            if (index < 0 || index > last) continue
            runOnRender {
                if (cache.get(index) != null) return@runOnRender
                val bitmap = renderPage(index) ?: return@runOnRender
                cache.put(index, bitmap)
            }
        }
    }

    /** 释放渲染线程与缓存；由 Activity 在 `onDestroy` 调用。 */
    fun shutdown() {
        renderExecutor.shutdownNow()
        cache.evictAll()
        recyclerViewRef = null
        inkEnabled = false
    }

    /** 缓存容量：堆内存 1/8。 */
    private fun cacheSizeBytes(): Int = (Runtime.getRuntime().maxMemory() / 8).toInt()

    companion object {
        private const val TAG = "PdfPageAdapter"
    }

    /**
     * 竖向模式的占位高度：优先构造参数 [defaultItemHeight]（由 Activity 传屏高），
     * 否则退化为宿主屏幕高度；只解析一次，后续复用。
     */
    private fun resolveDefaultHeight(context: Context): Int {
        if (resolvedDefaultHeight <= 0) {
            resolvedDefaultHeight = defaultItemHeight.takeIf { it > 0 }
                ?: context.resources.displayMetrics.heightPixels
        }
        return resolvedDefaultHeight
    }

    /** 在渲染线程逐页计算缩放后的页高（串行打开每一页，不持有 Page）。 */
    private fun computeHeights() {
        val targetWidth = renderWidth.coerceAtLeast(1)
        for (index in 0 until renderer.pageCount) {
            try {
                renderer.openPage(index).use { page ->
                    pageHeights[index] =
                        (page.height.toFloat() / page.width.toFloat() * targetWidth)
                            .roundToInt()
                            .coerceAtLeast(1)
                }
            } catch (e: Exception) {
                // renderer 已关闭或页索引异常：保持 0，绑定时退化为占位高度。
                Log.w(TAG, "computeHeights 第 $index 页失败（中止）", e)
                return
            }
        }
    }

    /** 把第 [index] 页渲染为位图；失败（如 renderer 已关闭）返回 `null`。 */
    private fun renderPage(index: Int): Bitmap? {
        val targetWidth = renderWidth.coerceAtLeast(1)
        // PdfRenderer 非线程安全且单页打开，串行化渲染。
        synchronized(renderer) {
            return try {
                renderer.openPage(index).use { page ->
                    val targetHeight =
                        (page.height.toFloat() / page.width.toFloat() * targetWidth)
                            .roundToInt()
                            .coerceAtLeast(1)
                    val bitmap =
                        Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                    // 先铺白底：PDF 默认透明背景。
                    bitmap.eraseColor(Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    bitmap
                }
            } catch (e: Exception) {
                // onDestroy 后 renderer 已关闭时避免崩溃。
                Log.w(TAG, "renderPage($index) 失败", e)
                null
            }
        }
    }

    /** 安全提交渲染任务：Adapter 已 shutdown 时静默丢弃，避免主线程崩溃。 */
    private fun runOnRender(block: () -> Unit) {
        try {
            renderExecutor.execute(block)
        } catch (e: RejectedExecutionException) {
            // Activity 已销毁，忽略。
        }
    }
}
