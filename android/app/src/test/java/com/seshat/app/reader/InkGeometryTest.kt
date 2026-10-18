package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [InkGeometry] 的坐标换算单测。
 *
 * 全部断言基于计划「设计 3」给出的四个数值示例，不依赖 Android 环境（纯 JVM）。
 */
class InkGeometryTest {

    /** 示例矩形 1：`view 1000×800` + `image 500×800` → 左右留白 250。 */
    private val letterboxed = DisplayRect(left = 250f, top = 0f, width = 500f, height = 800f)

    /** 示例矩形 2：`view 1000×800` + `image 2000×800` → 上下留白 200。 */
    private val pillarboxed = DisplayRect(left = 0f, top = 200f, width = 1000f, height = 400f)

    // ---- fitCenterRect ----

    @Test
    fun fitCenterRectLetterboxed() {
        // scale = min(1000/500, 800/800) = 1.0 → 高度铺满、左右各留白 250
        val rect = InkGeometry.fitCenterRect(
            viewWidth = 1000,
            viewHeight = 800,
            imageWidth = 500,
            imageHeight = 800,
        )
        assertEquals(letterboxed, rect)
    }

    @Test
    fun fitCenterRectPillarboxed() {
        // scale = min(1000/2000, 800/800) = 0.5 → 宽度铺满、上下各留白 200
        val rect = InkGeometry.fitCenterRect(
            viewWidth = 1000,
            viewHeight = 800,
            imageWidth = 2000,
            imageHeight = 800,
        )
        assertEquals(pillarboxed, rect)
    }

    @Test
    fun zeroImageSizeReturnsZeroRect() {
        // 图片尺寸未就绪（0×0）时不得抛异常，返回零矩形供调用方跳过绘制
        val rect = InkGeometry.fitCenterRect(
            viewWidth = 1000,
            viewHeight = 800,
            imageWidth = 0,
            imageHeight = 0,
        )
        assertEquals(DisplayRect(0f, 0f, 0f, 0f), rect)
    }

    @Test
    fun zeroViewSizeReturnsZeroRect() {
        // View 尚未测量（0×0）时同样返回零矩形
        val rect = InkGeometry.fitCenterRect(
            viewWidth = 0,
            viewHeight = 0,
            imageWidth = 500,
            imageHeight = 800,
        )
        assertEquals(DisplayRect(0f, 0f, 0f, 0f), rect)
    }

    // ---- toDisplay ----

    @Test
    fun toDisplayCenter() {
        val (x, y) = InkGeometry.toDisplay(InkPoint(0.5f, 0.5f), letterboxed)
        assertEquals(500f, x, 0.01f)
        assertEquals(400f, y, 0.01f)
    }

    // ---- toNormalized ----

    @Test
    fun toNormalizedCenter() {
        val point = InkGeometry.toNormalized(500f, 400f, letterboxed)
        assertEquals(0.5f, point.x, 0.01f)
        assertEquals(0.5f, point.y, 0.01f)
    }

    @Test
    fun toNormalizedTopLeft() {
        // 上下留白 200：View 内 y=200 才是图片顶边
        val point = InkGeometry.toNormalized(0f, 200f, pillarboxed)
        assertEquals(0f, point.x, 0.01f)
        assertEquals(0f, point.y, 0.01f)
    }

    @Test
    fun toNormalizedBottomRight() {
        val point = InkGeometry.toNormalized(1000f, 600f, pillarboxed)
        assertEquals(1f, point.x, 0.01f)
        assertEquals(1f, point.y, 0.01f)
    }

    @Test
    fun toNormalizedClampsOutOfBounds() {
        // 手指落在留白区（View 坐标超出显示矩形）时夹紧到 0..1
        val point = InkGeometry.toNormalized(-50f, 900f, letterboxed)
        assertEquals(0f, point.x, 0.01f)
        assertEquals(1f, point.y, 0.01f)
    }

    // ---- strokeWidthToPx ----

    @Test
    fun strokeWidthToPx() {
        // 0.01 × 500 = 5px
        assertEquals(5f, InkGeometry.strokeWidthToPx(0.01f, letterboxed), 0.01f)
    }

    // ---- 往返一致 ----

    @Test
    fun roundTripFirstPoint() {
        val normalized = InkGeometry.toNormalized(600f, 300f, letterboxed)
        val (x, y) = InkGeometry.toDisplay(normalized, letterboxed)
        assertEquals(600f, x, 0.01f)
        assertEquals(300f, y, 0.01f)
    }

    @Test
    fun roundTripSecondPoint() {
        val normalized = InkGeometry.toNormalized(300f, 700f, letterboxed)
        val (x, y) = InkGeometry.toDisplay(normalized, letterboxed)
        assertEquals(300f, x, 0.01f)
        assertEquals(700f, y, 0.01f)
    }
}
