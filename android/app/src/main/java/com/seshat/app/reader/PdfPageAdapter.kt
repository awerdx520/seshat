package com.seshat.app.reader

import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.pdf.PdfRenderer
import android.view.ViewGroup
import android.widget.ImageView
import androidx.recyclerview.widget.RecyclerView
import kotlin.math.roundToInt

/**
 * [androidx.viewpager2.widget.ViewPager2] 的页面适配器：把 [PdfRenderer] 的每一页
 * 渲染为 [Bitmap]，显示在 [ImageView] 上。
 *
 * 渲染方案要点：
 * - `PdfRenderer` 同一时刻只允许打开一个 [PdfRenderer.Page]，因此每次绑定都
 *   「打开 → 渲染 → 关闭」，不跨绑定持有 Page。
 * - PDF 页面背景透明，先铺白底再渲染，避免深色主题下黑字不可读。
 * - 渲染宽度对齐屏幕宽度，交给 `FIT_CENTER` 缩放到可见区域。
 *
 * @param renderer   已打开的 [PdfRenderer]（生命周期由 Activity 管理，本类不负责关闭）。
 * @param renderWidth 目标渲染宽度（像素），高度按页面纵横比换算。
 *
 * 说明（MVP 局限）：渲染在主线程同步执行，超大页面或低端设备可能存在卡顿；
 * 后续可迁移到后台线程 + 页面位图 LRU 缓存。
 */
class PdfPageAdapter(
    private val renderer: PdfRenderer,
    private val renderWidth: Int,
) : RecyclerView.Adapter<PdfPageAdapter.PageViewHolder>() {

    /** 单页视图：一个白底 [ImageView]。 */
    class PageViewHolder(val imageView: ImageView) : RecyclerView.ViewHolder(imageView)

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): PageViewHolder {
        val image = ImageView(parent.context).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            scaleType = ImageView.ScaleType.FIT_CENTER
            setBackgroundColor(Color.WHITE)
        }
        return PageViewHolder(image)
    }

    override fun getItemCount(): Int = renderer.pageCount

    override fun onBindViewHolder(holder: PageViewHolder, position: Int) {
        holder.imageView.setImageBitmap(renderPage(position))
    }

    /** 把第 [index] 页渲染为位图。 */
    private fun renderPage(index: Int): Bitmap {
        // PdfRenderer 非线程安全且单页打开，串行化渲染。
        synchronized(renderer) {
            renderer.openPage(index).use { page ->
                val targetWidth = renderWidth.coerceAtLeast(1)
                val targetHeight =
                    (page.height.toFloat() / page.width.toFloat() * targetWidth)
                        .roundToInt()
                        .coerceAtLeast(1)
                val bitmap = Bitmap.createBitmap(targetWidth, targetHeight, Bitmap.Config.ARGB_8888)
                // 先铺白底：PDF 默认透明背景。
                bitmap.eraseColor(Color.WHITE)
                page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                return bitmap
            }
        }
    }
}
