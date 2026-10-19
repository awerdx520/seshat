package com.seshat.app.reader

import android.content.Context
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.Path
import android.util.AttributeSet
import android.view.MotionEvent
import android.view.View
import kotlin.math.abs

/**
 * 手写笔迹覆盖层，覆盖在页面 ImageView 之上。
 *
 * 职责：
 * - 按 [InkGeometry] 把归一化笔迹绘制成像素路径；
 * - 手写模式开启时拦截触摸并采样笔迹，落笔结束经 [onStrokeFinished] 交给宿主持久化。
 *
 * 注意：图片以 FIT_CENTER 显示时 View 内可能有留白（左右或上下），
 * 所有坐标换算必须经 [InkGeometry]，不能直接用 View 尺寸。
 */
class InkOverlayView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : View(context, attrs) {

    private val strokePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeCap = Paint.Cap.ROUND
        strokeJoin = Paint.Join.ROUND
    }

    /** 已持久化的笔迹（归一化坐标）。 */
    private var strokes: List<InkStroke> = emptyList()

    /** 图片的固有像素尺寸（渲染出的 bitmap 宽高），用于算 FIT_CENTER 显示矩形。 */
    private var imageWidth: Int = 0
    private var imageHeight: Int = 0

    /** 是否处于手写模式；关闭时不消费触摸事件。 */
    private var inkEnabled: Boolean = false

    /** 正在绘制的笔（归一化点）；空表示未落笔。 */
    private var currentPoints: MutableList<InkPoint> = mutableListOf()
    private var currentColor: Int = DEFAULT_COLOR
    private var currentWidth: Float = DEFAULT_WIDTH_NORMALIZED

    /** 当前笔型（新笔沿用；既有笔迹各自带自己的 style）。 */
    private var currentStyle: InkStyle = InkStyle.PEN

    /** 一笔完成的回调（宿主负责持久化）。 */
    var onStrokeFinished: ((InkStroke) -> Unit)? = null

    /** 设置该页已有的笔迹。 */
    fun setStrokes(value: List<InkStroke>) {
        strokes = value
        invalidate()
    }

    /**
     * 设置图片的原始像素尺寸（渲染出的 bitmap 宽高），用于计算 FIT_CENTER 显示矩形。
     * 传 0 时本层不绘制（等待下一次绑定给出有效尺寸）。
     */
    fun setImageSize(width: Int, height: Int) {
        if (imageWidth == width && imageHeight == height) return
        imageWidth = width
        imageHeight = height
        invalidate()
    }

    /** 开关手写模式；关闭时不消费触摸事件（交给 RecyclerView 滚动/点击翻页）。 */
    fun setInkEnabled(enabled: Boolean) {
        if (inkEnabled == enabled) return
        inkEnabled = enabled
        if (!enabled) currentPoints.clear()
        invalidate()
    }

    /** 设置后续新笔的颜色（面板选色）。 */
    fun setInkColor(color: Int) {
        if (currentColor == color) return
        currentColor = color
    }

    /** 设置后续新笔的归一化线宽（面板选粗细）。 */
    fun setInkWidth(width: Float) {
        if (currentWidth == width) return
        currentWidth = width
    }

    /** 设置后续新笔的笔型（面板选笔型）。 */
    fun setInkStyle(style: InkStyle) {
        if (currentStyle == style) return
        currentStyle = style
        invalidate()
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val rect = currentRect() ?: return
        strokes.forEach { drawStroke(canvas, it, rect) }
        if (currentPoints.isNotEmpty()) {
            drawStroke(canvas, InkStroke(currentColor, currentWidth, currentPoints, currentStyle), rect)
        }
    }

    /** 当前 FIT_CENTER 显示矩形；尺寸非法时返回 null。 */
    private fun currentRect(): DisplayRect? {
        val rect = InkGeometry.fitCenterRect(width, height, imageWidth, imageHeight)
        return if (rect.width <= 0f || rect.height <= 0f) null else rect
    }

    /** 把一画笔迹按显示矩形换算成像素路径并绘制（笔型决定透明度与线宽倍率）。 */
    private fun drawStroke(canvas: Canvas, stroke: InkStroke, rect: DisplayRect) {
        if (stroke.points.size < 2) return
        val path = Path()
        val first = InkGeometry.toDisplay(stroke.points.first(), rect)
        path.moveTo(first.first, first.second)
        for (index in 1 until stroke.points.size) {
            val point = InkGeometry.toDisplay(stroke.points[index], rect)
            path.lineTo(point.first, point.second)
        }
        strokePaint.color = stroke.color
        strokePaint.strokeWidth =
            InkGeometry.strokeWidthToPx(stroke.width, rect) * styleWidthScale(stroke.style)
        // 必须在 setColor 之后设 alpha：setColor 会把 alpha 覆盖成颜色自带的分量
        strokePaint.alpha = styleAlpha(stroke.style)
        canvas.drawPath(path, strokePaint)
    }

    /** 笔型 → 线宽倍率：钢笔 1×、马克笔 2.2×、荧光笔 3.5×。 */
    private fun styleWidthScale(style: InkStyle): Float = when (style) {
        InkStyle.PEN -> 1f
        InkStyle.MARKER -> 2.2f
        InkStyle.HIGHLIGHTER -> 3.5f
    }

    /** 笔型 → 不透明度：钢笔不透明、马克笔半透明、荧光笔更淡。 */
    private fun styleAlpha(style: InkStyle): Int = when (style) {
        InkStyle.PEN -> 255
        InkStyle.MARKER -> 170
        InkStyle.HIGHLIGHTER -> 90
    }

    /** 无障碍语义：本 View 消费点击手势（实际落笔逻辑在 onTouchEvent）。 */
    override fun performClick(): Boolean {
        super.performClick()
        return true
    }

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (!inkEnabled) return false
        // 多指同时落屏时丢弃当前笔，避免第二指的点被并入同一笔画
        if (event.pointerCount > 1) {
            if (currentPoints.isNotEmpty()) {
                parent?.requestDisallowInterceptTouchEvent(false)
                currentPoints = mutableListOf()
                invalidate()
            }
            return true
        }
        val rect = currentRect() ?: return false
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                // 抢在 RecyclerView 之前消费手势，否则横向拖动会被当作滚动/吸附
                parent?.requestDisallowInterceptTouchEvent(true)
                currentPoints = mutableListOf(InkGeometry.toNormalized(event.x, event.y, rect))
                invalidate()
            }

            MotionEvent.ACTION_MOVE -> {
                val point = InkGeometry.toNormalized(event.x, event.y, rect)
                val last = currentPoints.lastOrNull()
                val farEnough = last == null ||
                    abs(last.x - point.x) * rect.width > MIN_STEP_PX ||
                    abs(last.y - point.y) * rect.height > MIN_STEP_PX
                if (farEnough) {
                    currentPoints.add(point)
                    invalidate()
                }
            }

            MotionEvent.ACTION_UP -> {
                parent?.requestDisallowInterceptTouchEvent(false)
                if (currentPoints.size >= 2) {
                    onStrokeFinished?.invoke(
                        InkStroke(currentColor, currentWidth, currentPoints.toList(), currentStyle),
                    )
                }
                currentPoints = mutableListOf()
                invalidate()
                performClick()
            }

            MotionEvent.ACTION_CANCEL -> {
                // 手势被系统取消（来电/父容器抢占/多指切换）：丢弃当前笔，不持久化
                parent?.requestDisallowInterceptTouchEvent(false)
                currentPoints = mutableListOf()
                invalidate()
            }
        }
        return true
    }

    companion object {
        /** 默认笔色（红）。 */
        const val DEFAULT_COLOR: Int = 0xFFE53935.toInt()

        /** 默认归一化线宽（相对页宽）。 */
        const val DEFAULT_WIDTH_NORMALIZED: Float = 0.004f

        /** 采样最小步长（像素），避免同一点堆积过多顶点。 */
        private const val MIN_STEP_PX = 1.5f
    }
}
