package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [InkAnnotationMapper] 的纯 JVM 单元测试（M10.3 / T6）。
 *
 * 覆盖面：颜色格式（含 alpha）与 [LocationCodec] 的往返、归一化线宽 → pt、页号 0-based → 1-based、
 * 多点笔迹的坐标换算、以及「补登前先按本地幂等键去重」。
 */
class InkAnnotationMapperTest {

    /** Letter 尺寸（PDF point，612 × 792），便于整除验算。 */
    private val pageWidthPt = 612.0
    private val pageHeightPt = 792.0

    private fun stroke(
        color: Int = 0xFFE53935.toInt(),
        width: Float = 0.004f,
        points: List<Pair<Float, Float>> = emptyList(),
    ) = InkStroke(
        color = color,
        width = width,
        points = points.map { InkPoint(it.first, it.second) },
    )

    private fun inkAnnotation(
        location: String,
        kind: String = InkAnnotationMapper.KIND_INK,
        text: String = "",
    ) = PdfAnnotation(
        id = 1L,
        documentId = "doc",
        location = location,
        text = text,
        createdAt = 0L,
        updatedAt = 0L,
        kind = kind,
    )

    // ---- ① 颜色格式（含 alpha）与 encodeInk 往返 ----

    @Test
    fun colorHexKeepsAlphaAndUsesUppercase() {
        assertEquals("#FFE53935", InkAnnotationMapper.colorHex(0xFFE53935.toInt()))
        // 半透明（马克笔/荧光笔）必须保住 alpha，否则跨端还原会变成实心粗线
        assertEquals("#80FF0000", InkAnnotationMapper.colorHex(0x80FF0000.toInt()))
        // 补零到 8 位：alpha = 0 时不能退化成 6 位
        assertEquals("#00000000", InkAnnotationMapper.colorHex(0))
        assertEquals("#000000FF", InkAnnotationMapper.colorHex(0xFF))
    }

    @Test
    fun inkLocationColorSurvivesCodecRoundTrip() {
        val location = InkAnnotationMapper.inkLocation(
            pageIndex = 0,
            // 必须带非空点集：inkLocation 对空笔迹有意返回 null（见 emptyPointsProduceNoLocation）
            stroke = stroke(color = 0x80FF0000.toInt(), points = listOf(0.5f to 0.5f)),
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
        )
        val parsed = LocationCodec.parse(requireNotNull(location)) as LocationCodec.Parsed.PageInk
        assertEquals("#80FF0000", parsed.color)
    }

    // ---- ② 线宽归一化 → pt ----

    @Test
    fun widthPtMultipliesPageWidth() {
        assertEquals(2.448, InkAnnotationMapper.widthPt(0.004f, pageWidthPt), 1e-6)
        // 同一归一化线宽在不同页宽上得到不同 pt：窄页面不能画出「粗得离谱」的线
        assertEquals(1.224, InkAnnotationMapper.widthPt(0.004f, pageWidthPt / 2), 1e-6)
    }

    @Test
    fun widthPtIsEncodedWithTwoDecimals() {
        val location = InkAnnotationMapper.inkLocation(
            pageIndex = 0,
            stroke = stroke(width = 0.004f, points = listOf(0.5f to 0.5f)),
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
        )
        // 0.004 × 612 = 2.448 → 两位小数 2.45
        assertEquals("page:1;ink:#FFE53935,2.45,306.00,396.00", location)
    }

    @Test
    fun widthPtClampsIllegalInput() {
        assertEquals(0.0, InkAnnotationMapper.widthPt(Float.NaN, pageWidthPt), 0.0)
        assertEquals(0.0, InkAnnotationMapper.widthPt(-0.5f, pageWidthPt), 0.0)
        // 页宽非法（尺寸未就绪）：不给 NaN/Infinity，落 0 保证 location 仍可解析
        assertEquals(0.0, InkAnnotationMapper.widthPt(0.004f, 0.0), 0.0)
        assertEquals(0.0, InkAnnotationMapper.widthPt(0.004f, Double.NaN), 0.0)
    }

    // ---- ③ 多点笔迹：page 1-based + 坐标 → 可被 parse 回 PageInk ----

    @Test
    fun multiPointStrokeParsesBackWithOneBasedPage() {
        // pageIndex = 2（0-based）→ location 里的 page:3（1-based）
        val location = InkAnnotationMapper.inkLocation(
            pageIndex = 2,
            stroke = stroke(points = listOf(0.0f to 0.0f, 0.5f to 0.25f, 1.0f to 1.0f)),
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
        )
        assertEquals(
            "page:3;ink:#FFE53935,2.45,0.00,0.00,306.00,198.00,612.00,792.00",
            location,
        )
        val parsed = LocationCodec.parse(requireNotNull(location)) as LocationCodec.Parsed.PageInk
        assertEquals(3, parsed.page)
        assertEquals(2.45, parsed.widthPt, 1e-9)
        assertEquals(
            listOf(0.0 to 0.0, 306.0 to 198.0, 612.0 to 792.0),
            parsed.points,
        )
    }

    @Test
    fun outOfRangeNormalizedPointsAreClamped() {
        // 留白区误采样（<0 或 >1）不得越界到页面外，否则跨端会画在页边之外
        val location = InkAnnotationMapper.inkLocation(
            pageIndex = 0,
            stroke = stroke(points = listOf(-0.5f to -0.5f, 1.5f to 1.5f)),
            pageWidthPt = pageWidthPt,
            pageHeightPt = pageHeightPt,
        )
        assertEquals("page:1;ink:#FFE53935,2.45,0.00,0.00,612.00,792.00", location)
    }

    @Test
    fun emptyPointsProduceNoLocation() {
        assertNull(InkAnnotationMapper.inkLocation(0, stroke(), pageWidthPt, pageHeightPt))
    }

    // ---- ④ 幂等键判定（同 location 不得重复补登）----

    @Test
    fun keySeparatesKindLocationAndText() {
        val ink = InkAnnotationMapper.key("ink", "page:1;ink:c,1.00", "")
        assertNotEquals(ink, InkAnnotationMapper.key("note", "page:1;ink:c,1.00", ""))
        // NUL 分隔：文本里含分隔符也不会撞键
        assertNotEquals(
            InkAnnotationMapper.key("ink", "a", "b"),
            InkAnnotationMapper.key("ink", "a\u0000b", ""),
        )
    }

    @Test
    fun pendingInkLocationsSkipsAlreadyRegistered() {
        val pages = listOf(
            PdfInkPage(
                page = 0,
                strokes = listOf(
                    stroke(points = listOf(0.5f to 0.5f)),
                    stroke(points = listOf(0.25f to 0.25f)),
                ),
            ),
        )
        val first = requireNotNull(
            InkAnnotationMapper.inkLocation(0, pages[0].strokes[0], pageWidthPt, pageHeightPt),
        )
        val existing = listOf(inkAnnotation(first))

        val pending = InkAnnotationMapper.pendingInkLocations(pages, existing) { pageWidthPt to pageHeightPt }

        // 第一条已在本地 → 跳过；只剩第二条
        assertEquals(1, pending.size)
        assertEquals(
            requireNotNull(InkAnnotationMapper.inkLocation(0, pages[0].strokes[1], pageWidthPt, pageHeightPt)),
            pending[0],
        )
        // 把本次结果入库后再补登应为空——「重复打开不产生重复条目」
        val afterRegister = existing + pending.map { inkAnnotation(it) }
        assertTrue(
            InkAnnotationMapper.pendingInkLocations(pages, afterRegister) { pageWidthPt to pageHeightPt }.isEmpty(),
        )
    }

    @Test
    fun pendingInkLocationsDeduplicatesIdenticalStrokes() {
        // 两笔完全重合 → location 相同 → 只登记一条（服务端 (kind,location,text) 也会去重）
        val pages = listOf(
            PdfInkPage(
                page = 1,
                strokes = listOf(
                    stroke(points = listOf(0.5f to 0.5f)),
                    stroke(points = listOf(0.5f to 0.5f)),
                ),
            ),
        )
        val pending = InkAnnotationMapper.pendingInkLocations(pages, emptyList()) { pageWidthPt to pageHeightPt }
        assertEquals(1, pending.size)
        // page 0-based 1 → 1-based 2
        assertTrue(pending[0].startsWith("page:2;ink:"))
    }

    @Test
    fun pendingInkLocationsSkipsPagesWithoutSizeAndEmptyStrokes() {
        val pages = listOf(
            PdfInkPage(page = 0, strokes = emptyList()),
            PdfInkPage(page = 3, strokes = listOf(stroke(points = listOf(0.5f to 0.5f)))),
            PdfInkPage(page = 4, strokes = listOf(stroke(points = listOf(0.5f to 0.5f)))),
        )
        val pending = InkAnnotationMapper.pendingInkLocations(pages, emptyList()) { page ->
            // 第 3 页尺寸取不到（渲染器已关闭）→ 跳过；第 4 页正常
            if (page == 3) null else pageWidthPt to pageHeightPt
        }
        assertEquals(1, pending.size)
        assertTrue(pending[0].startsWith("page:5;ink:"))
    }

    @Test
    fun pendingInkLocationsAreOrderedByPage() {
        val pages = listOf(
            PdfInkPage(page = 5, strokes = listOf(stroke(points = listOf(0.1f to 0.1f)))),
            PdfInkPage(page = 2, strokes = listOf(stroke(points = listOf(0.2f to 0.2f)))),
        )
        val pending = InkAnnotationMapper.pendingInkLocations(pages, emptyList()) { pageWidthPt to pageHeightPt }
        assertEquals(2, pending.size)
        assertTrue(pending[0].startsWith("page:3;ink:"))
        assertTrue(pending[1].startsWith("page:6;ink:"))
    }

    // ---- 镜像批注的形态 ----

    @Test
    fun inkAnnotationMirrorsContractShape() {
        val annotation = InkAnnotationMapper.inkAnnotation("uid-1", "page:2;ink:#FF000000,1.00", now = 123L)
        assertEquals(0L, annotation.id) // 0 → store 分配 nextId，绝不复用服务端 id
        assertEquals("uid-1", annotation.documentId)
        assertEquals(InkAnnotationMapper.KIND_INK, annotation.kind)
        assertEquals("", annotation.text) // ink 的 text 恒空串（服务端按 kind 放宽校验）
        assertEquals("", annotation.selectedText)
        assertNull(annotation.serverId)
        assertTrue(annotation.dirty) // 待上行
        assertEquals(123L, annotation.createdAt)
        assertEquals(123L, annotation.updatedAt)
    }

    @Test
    fun isRegisteredOnlyMatchesInkKindAndEmptyText() {
        val location = "page:1;ink:#FF000000,1.00,10.00,10.00"
        assertTrue(InkAnnotationMapper.isRegistered(listOf(inkAnnotation(location)), location))
        // 同 location 但 kind 不同（实际不会发生，但语义上必须区分）
        assertFalse(
            InkAnnotationMapper.isRegistered(
                listOf(inkAnnotation(location, kind = "note", text = "备注")),
                location,
            ),
        )
        assertFalse(InkAnnotationMapper.isRegistered(emptyList(), location))
    }
}
