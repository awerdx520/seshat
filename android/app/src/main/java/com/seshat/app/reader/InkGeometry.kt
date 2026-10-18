package com.seshat.app.reader

import kotlin.math.min

/** 图片在 View 内的显示矩形（自定义数据类，避免引入 Android 图形框架的 RectF，保持纯 JVM 可测）。 */
data class DisplayRect(val left: Float, val top: Float, val width: Float, val height: Float)

/**
 * 手写笔迹的坐标换算（纯逻辑，无 Android 依赖，可 JVM 单测）。
 *
 * 约定：笔迹存**归一化坐标**（相对图片显示矩形的 0..1），绘制与触摸时在像素坐标之间往返换算。
 * 图片以 FIT_CENTER 显示，因此 View 内可能有留白（左右或上下）。
 */
object InkGeometry {

    /** 计算 FIT_CENTER 下图片在 View 内的显示矩形；尺寸非法时返回零矩形。 */
    fun fitCenterRect(viewWidth: Int, viewHeight: Int, imageWidth: Int, imageHeight: Int): DisplayRect {
        if (viewWidth <= 0 || viewHeight <= 0 || imageWidth <= 0 || imageHeight <= 0) {
            return DisplayRect(0f, 0f, 0f, 0f)
        }
        val scale = min(viewWidth.toFloat() / imageWidth, viewHeight.toFloat() / imageHeight)
        val width = imageWidth * scale
        val height = imageHeight * scale
        val left = (viewWidth - width) / 2f
        val top = (viewHeight - height) / 2f
        return DisplayRect(left, top, width, height)
    }

    /** 像素（相对 View）→ 归一化（相对显示矩形）；越界夹紧到 0..1。 */
    fun toNormalized(px: Float, py: Float, rect: DisplayRect): InkPoint {
        if (rect.width <= 0f || rect.height <= 0f) return InkPoint(0f, 0f)
        val nx = ((px - rect.left) / rect.width).coerceIn(0f, 1f)
        val ny = ((py - rect.top) / rect.height).coerceIn(0f, 1f)
        return InkPoint(nx, ny)
    }

    /** 归一化 → 像素（相对 View）。 */
    fun toDisplay(point: InkPoint, rect: DisplayRect): Pair<Float, Float> =
        (rect.left + point.x * rect.width) to (rect.top + point.y * rect.height)

    /** 归一化线宽 → 像素。 */
    fun strokeWidthToPx(normalized: Float, rect: DisplayRect): Float =
        (normalized * rect.width).coerceAtLeast(1f)
}
