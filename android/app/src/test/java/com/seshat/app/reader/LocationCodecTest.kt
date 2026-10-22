package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LocationCodec] 的 location 编解码单测（M10.3 T2）。
 *
 * 覆盖范围：
 * - 四种 location 形态的 `parse`（`page:<n>` / `page:<n>;rect:` / `page:<n>;ink:` / `chapter:<i>@<s>-<e>`）；
 * - `encodeInk` 的两位小数、多点、越界夹紧、页面尺寸未知与空点列表的降级形态；
 * - `encodeChapter` 的格式与往返（含 offset=0 边界）；
 * - 全部非法输入的 `Unknown` 兜底（**不抛异常**）；
 * - 编码结果再 `parse` 后页号与原值一致（`pageFromLocation` 兼容性）。
 *
 * 纯 JVM，无 Android 依赖。
 */
class LocationCodecTest {

    /** A4 尺寸（PDF point），作为 ink 编码的页面基准。 */
    private val a4Width = 595.0
    private val a4Height = 842.0

    /** Letter 尺寸（PDF point），用于多点与精度用例。 */
    private val letterWidth = 612.0
    private val letterHeight = 792.0

    /** 从任意 PDF location 取页号（等价于各调用点的 `pageFromLocation`）；非 PDF 形态返回 null。 */
    private fun pageOf(location: String): Int? = when (val parsed = LocationCodec.parse(location)) {
        is LocationCodec.Parsed.Page -> parsed.page
        is LocationCodec.Parsed.PageRect -> parsed.page
        is LocationCodec.Parsed.PageInk -> parsed.page
        is LocationCodec.Parsed.Chapter -> null
        is LocationCodec.Parsed.Unknown -> null
    }

    // ---- parse：四种合法形态 ----

    @Test
    fun parsePageOnly() {
        assertEquals(LocationCodec.Parsed.Page(12), LocationCodec.parse("page:12"))
    }

    @Test
    fun parsePageRect() {
        // 既有形态（M10.4 已定稿）：矩形四角为 PDF point，两位小数
        assertEquals(
            LocationCodec.Parsed.PageRect(7, 10.5, 20.25, 110.75, 220.0),
            LocationCodec.parse("page:7;rect:10.5,20.25,110.75,220"),
        )
    }

    @Test
    fun parsePageInk() {
        assertEquals(
            LocationCodec.Parsed.PageInk(12, "#FFFF0000", 2.5, listOf(10.0 to 20.0)),
            LocationCodec.parse("page:12;ink:#FFFF0000,2.50,10.00,20.00"),
        )
    }

    @Test
    fun parsePageInkMultiplePoints() {
        val parsed = LocationCodec.parse("page:3;ink:#FF000000,3.00,0.00,0.00,612.00,792.00,1.50,2.25")
        assertEquals(
            LocationCodec.Parsed.PageInk(
                3,
                "#FF000000",
                3.0,
                listOf(0.0 to 0.0, 612.0 to 792.0, 1.5 to 2.25),
            ),
            parsed,
        )
    }

    @Test
    fun parseChapter() {
        assertEquals(LocationCodec.Parsed.Chapter(3, 100, 200), LocationCodec.parse("chapter:3@100-200"))
    }

    @Test
    fun parseChapterZeroOffsets() {
        // 章内首个字符的边界：spine 0 / start 0 / end 0 均合法
        assertEquals(LocationCodec.Parsed.Chapter(0, 0, 0), LocationCodec.parse("chapter:0@0-0"))
    }

    @Test
    fun parseTrimsSurroundingWhitespace() {
        // 服务端串可能带首尾空白；trim 后仍按合法形态解析
        assertEquals(LocationCodec.Parsed.Page(12), LocationCodec.parse("  page:12  "))
    }

    // ---- encodeInk：格式、往返、精度、夹紧 ----

    @Test
    fun encodeInkSinglePointFormat() {
        // 0.5 × 595 = 297.5、0.5 × 842 = 421 → 两位小数
        val encoded = LocationCodec.encodeInk(
            page = 12,
            color = "#FFFF0000",
            widthPt = 2.5,
            points = listOf(InkPoint(0.5f, 0.5f)),
            pageWidthPt = a4Width,
            pageHeightPt = a4Height,
        )
        assertEquals("page:12;ink:#FFFF0000,2.50,297.50,421.00", encoded)
    }

    @Test
    fun encodeInkMultiplePointsRoundTrip() {
        val points = listOf(InkPoint(0f, 0f), InkPoint(1f, 1f), InkPoint(0.25f, 0.75f))
        val encoded = LocationCodec.encodeInk(3, "#FF000000", 3.0, points, letterWidth, letterHeight)
        assertEquals(
            "page:3;ink:#FF000000,3.00,0.00,0.00,612.00,792.00,153.00,594.00",
            encoded,
        )
        val parsed = LocationCodec.parse(encoded)
        assertTrue(parsed is LocationCodec.Parsed.PageInk)
        assertEquals(
            LocationCodec.Parsed.PageInk(
                3,
                "#FF000000",
                3.0,
                listOf(0.0 to 0.0, 612.0 to 792.0, 153.0 to 594.0),
            ),
            parsed,
        )
    }

    @Test
    fun encodeInkClampsOutOfRangePoints() {
        // 归一化点越界（留白区误采）时夹紧到 0..1，与 InkGeometry.toNormalized 的既有约定一致
        val encoded = LocationCodec.encodeInk(
            page = 1,
            color = "c",
            widthPt = 1.0,
            points = listOf(InkPoint(-0.5f, 1.5f)),
            pageWidthPt = 100.0,
            pageHeightPt = 200.0,
        )
        assertEquals("page:1;ink:c,1.00,0.00,200.00", encoded)
    }

    @Test
    fun encodeInkTwoDecimalPrecision() {
        // 0.1f × 612 = 61.2000…、0.3f × 792 = 237.6000… → 截断为两位小数
        val encoded = LocationCodec.encodeInk(
            page = 2,
            color = "c",
            widthPt = 1.5,
            points = listOf(InkPoint(0.1f, 0.3f)),
            pageWidthPt = letterWidth,
            pageHeightPt = letterHeight,
        )
        assertEquals("page:2;ink:c,1.50,61.20,237.60", encoded)
    }

    @Test
    fun encodeInkEmptyPointsOmitsCoordinates() {
        // 空点列表：不带坐标，但保留页码/颜色/线宽，且该串必须仍可被 parse（编码闭合）
        val encoded = LocationCodec.encodeInk(
            page = 3,
            color = "#FF000000",
            widthPt = 2.0,
            points = emptyList(),
            pageWidthPt = a4Width,
            pageHeightPt = a4Height,
        )
        assertEquals("page:3;ink:#FF000000,2.00", encoded)
        assertEquals(
            LocationCodec.Parsed.PageInk(3, "#FF000000", 2.0, emptyList()),
            LocationCodec.parse(encoded),
        )
    }

    @Test
    fun encodeInkZeroPageSizeOmitsCoordinates() {
        // 页面尺寸未知（0×0）：点无法换算为 PDF point，降级为不带坐标的形态
        val encoded = LocationCodec.encodeInk(5, "#FF0000FF", 1.0, listOf(InkPoint(0.5f, 0.5f)), 0.0, 0.0)
        assertEquals("page:5;ink:#FF0000FF,1.00", encoded)
        assertEquals(LocationCodec.Parsed.PageInk(5, "#FF0000FF", 1.0, emptyList()), LocationCodec.parse(encoded))
    }

    @Test
    fun encodeInkNegativePageSizeOmitsCoordinates() {
        // 任一维非正都不能换算（负宽高是无意义的输入），同样降级
        val encoded = LocationCodec.encodeInk(5, "c", 1.0, listOf(InkPoint(0.5f, 0.5f)), -10.0, 20.0)
        assertEquals("page:5;ink:c,1.00", encoded)
    }

    @Test
    fun encodeInkNegativeWidthClampedToZero() {
        val encoded = LocationCodec.encodeInk(1, "c", -2.0, emptyList(), 100.0, 100.0)
        assertEquals("page:1;ink:c,0.00", encoded)
    }

    @Test
    fun encodeInkSanitizesColor() {
        // 颜色中的分隔符（, ; @ 空白）会破坏 location 结构，编码时剔除，保证结果必可 parse
        val encoded = LocationCodec.encodeInk(1, "a,b;c @d", 1.0, emptyList(), 100.0, 100.0)
        assertEquals("page:1;ink:abcd,1.00", encoded)
        assertTrue(LocationCodec.parse(encoded) is LocationCodec.Parsed.PageInk)
    }

    @Test
    fun encodeInkBlankColorFallsBackToPlaceholder() {
        // 空颜色回退占位值 "0"（表示未指定），避免产出 "page:1;ink:,1.00" 这种不可解析串
        val encoded = LocationCodec.encodeInk(1, "", 1.0, emptyList(), 100.0, 100.0)
        assertEquals("page:1;ink:0,1.00", encoded)
        assertTrue(LocationCodec.parse(encoded) is LocationCodec.Parsed.PageInk)
    }

    @Test
    fun encodeInkZeroPageClampedToOne() {
        // 页号为 1-based，0 并入 1（保证编码结果必然可 parse）
        val encoded = LocationCodec.encodeInk(0, "c", 1.0, emptyList(), 100.0, 100.0)
        assertEquals("page:1;ink:c,1.00", encoded)
    }

    // ---- pageFromLocation 兼容性 ----

    @Test
    fun pageNumberSurvivesInkRoundTrip() {
        val encoded = LocationCodec.encodeInk(
            page = 42,
            color = "#FF00FF00",
            widthPt = 2.5,
            points = listOf(InkPoint(0.2f, 0.4f), InkPoint(0.6f, 0.8f)),
            pageWidthPt = a4Width,
            pageHeightPt = a4Height,
        )
        assertEquals(42, pageOf(encoded))
    }

    @Test
    fun pageNumberReadableFromAllPdfForms() {
        // 三种 PDF 形态都能被同一个 pageFromLocation 取到页号（服务端存量串混读）
        assertEquals(12, pageOf("page:12"))
        assertEquals(12, pageOf("page:12;rect:1.00,2.00,3.00,4.00"))
        assertEquals(12, pageOf("page:12;ink:#FF0000,2.00,10.00,20.00"))
        assertNull(pageOf("chapter:12@0-10"))
        assertNull(pageOf("garbage"))
    }

    // ---- encodeChapter ----

    @Test
    fun encodeChapterFormat() {
        assertEquals("chapter:3@100-200", LocationCodec.encodeChapter(3, 100, 200))
    }

    @Test
    fun encodeChapterRoundTrip() {
        val encoded = LocationCodec.encodeChapter(7, 30, 45)
        assertEquals(LocationCodec.Parsed.Chapter(7, 30, 45), LocationCodec.parse(encoded))
    }

    @Test
    fun encodeChapterZeroOffsetsRoundTrip() {
        // offset=0 边界（章首空选区）必须可编码也可解析
        assertEquals("chapter:0@0-0", LocationCodec.encodeChapter(0, 0, 0))
        assertEquals(LocationCodec.Parsed.Chapter(0, 0, 0), LocationCodec.parse("chapter:0@0-0"))
    }

    @Test
    fun encodeChapterNegativeValuesClampedToZero() {
        // 负数偏移无意义；夹紧到 0 以保证编码结果必然可 parse
        assertEquals("chapter:0@0-5", LocationCodec.encodeChapter(-2, -1, 5))
    }

    // ---- 非法输入：一律 Unknown，且不抛异常 ----

    @Test
    fun parseRejectsZeroPage() {
        // 页号 1-based，0 非法
        assertEquals(LocationCodec.Parsed.Unknown("page:0"), LocationCodec.parse("page:0"))
    }

    @Test
    fun parseRejectsNegativePage() {
        assertEquals(LocationCodec.Parsed.Unknown("page:-3"), LocationCodec.parse("page:-3"))
    }

    @Test
    fun parseRejectsPageWithoutNumber() {
        assertEquals(LocationCodec.Parsed.Unknown("page:"), LocationCodec.parse("page:"))
    }

    @Test
    fun parseRejectsMissingInkWidth() {
        // 缺 widthPt 字段
        assertEquals(LocationCodec.Parsed.Unknown("page:12;ink:red"), LocationCodec.parse("page:12;ink:red"))
    }

    @Test
    fun parseRejectsOddCoordinateCount() {
        // 坐标必须成对出现
        assertEquals(
            LocationCodec.Parsed.Unknown("page:12;ink:red,2.00,10.00"),
            LocationCodec.parse("page:12;ink:red,2.00,10.00"),
        )
    }

    @Test
    fun parseRejectsNonNumericCoordinate() {
        assertEquals(
            LocationCodec.Parsed.Unknown("page:12;ink:red,2.00,10.00,abc"),
            LocationCodec.parse("page:12;ink:red,2.00,10.00,abc"),
        )
    }

    @Test
    fun parseRejectsEmptyRectBody() {
        assertEquals(LocationCodec.Parsed.Unknown("page:12;rect:"), LocationCodec.parse("page:12;rect:"))
    }

    @Test
    fun parseRejectsRectWithWrongFieldCount() {
        assertEquals(LocationCodec.Parsed.Unknown("page:12;rect:1,2,3"), LocationCodec.parse("page:12;rect:1,2,3"))
    }

    @Test
    fun parseRejectsUnknownSegment() {
        assertEquals(LocationCodec.Parsed.Unknown("page:12;foo:1"), LocationCodec.parse("page:12;foo:1"))
    }

    @Test
    fun parseRejectsExtraSegments() {
        assertEquals(
            LocationCodec.Parsed.Unknown("page:1;rect:1,2,3,4;ink:c,1"),
            LocationCodec.parse("page:1;rect:1,2,3,4;ink:c,1"),
        )
    }

    @Test
    fun parseRejectsChapterWithoutAt() {
        assertEquals(LocationCodec.Parsed.Unknown("chapter:3"), LocationCodec.parse("chapter:3"))
    }

    @Test
    fun parseRejectsChapterWithoutDash() {
        // 缺 `-` 分隔符（只有 start）
        assertEquals(LocationCodec.Parsed.Unknown("chapter:3@100"), LocationCodec.parse("chapter:3@100"))
    }

    @Test
    fun parseRejectsEmptyString() {
        assertEquals(LocationCodec.Parsed.Unknown(""), LocationCodec.parse(""))
    }

    @Test
    fun parseRejectsBlankString() {
        assertEquals(LocationCodec.Parsed.Unknown("   "), LocationCodec.parse("   "))
    }

    @Test
    fun parseRejectsUnknownPrefix() {
        assertEquals(LocationCodec.Parsed.Unknown("foo:bar"), LocationCodec.parse("foo:bar"))
        // 旧 EPUB 形态（`chapter-<n>`，无冒号）不在本轮解析范围，返回 Unknown 由旧逻辑兜底
        assertEquals(LocationCodec.Parsed.Unknown("chapter-3"), LocationCodec.parse("chapter-3"))
    }

    // ---- R3：边界与防御上限 ----

    /** 倒置区间（`start > end`）是数据损坏：判非法返回 Unknown，不可当半开区间照单全收。 */
    @Test
    fun parseRejectsChapterWithInvertedRange() {
        assertEquals(
            LocationCodec.Parsed.Unknown("chapter:5@20-10"),
            LocationCodec.parse("chapter:5@20-10"),
        )
    }

    /** `start == end`（空选区）仍合法：不是倒置，`encodeChapter` 也可能产出该形态。 */
    @Test
    fun parseAcceptsChapterWithEqualOffsets() {
        assertEquals(
            LocationCodec.Parsed.Chapter(spineIndex = 5, startOffset = 7, endOffset = 7),
            LocationCodec.parse("chapter:5@7-7"),
        )
    }

    /** 编码侧对倒置区间归一化为 `min-max`（保证「编码结果必然可解析」的闭合性）。 */
    @Test
    fun encodeChapterNormalizesInvertedRange() {
        assertEquals("chapter:5@10-20", LocationCodec.encodeChapter(5, 20, 10))
        assertEquals(
            LocationCodec.Parsed.Chapter(spineIndex = 5, startOffset = 10, endOffset = 20),
            LocationCodec.parse(LocationCodec.encodeChapter(5, 20, 10)),
        )
    }

    /** 点数恰好等于 [LocationCodec.MAX_INK_POINTS] 时正常解析（上限是「允许」而非「拒绝」）。 */
    @Test
    fun parseAcceptsInkAtPointLimit() {
        val location = inkLocation(LocationCodec.MAX_INK_POINTS)
        val parsed = LocationCodec.parse(location)
        assertTrue("恰好上限必须可解析，实际 $parsed", parsed is LocationCodec.Parsed.PageInk)
        assertEquals(LocationCodec.MAX_INK_POINTS, (parsed as LocationCodec.Parsed.PageInk).points.size)
    }

    /** 点数超过上限（`MAX + 1`）返回 Unknown，**不抛异常**（避免超长 location 引发内存膨胀）。 */
    @Test
    fun parseRejectsInkAbovePointLimit() {
        val location = inkLocation(LocationCodec.MAX_INK_POINTS + 1)
        assertEquals(LocationCodec.Parsed.Unknown(location), LocationCodec.parse(location))
    }

    /** 编码侧同源截断：`MAX + 1` 个点编码后再解析仍可解析（闭合性），点数等于上限。 */
    @Test
    fun encodeInkTruncatesAtPointLimit() {
        val points = (0 until LocationCodec.MAX_INK_POINTS + 1).map { InkPoint(0.5f, 0.5f) }
        val encoded = LocationCodec.encodeInk(
            page = 3,
            color = "ff0000",
            widthPt = 1.5,
            points = points,
            pageWidthPt = a4Width,
            pageHeightPt = a4Height,
        )
        val parsed = LocationCodec.parse(encoded)
        assertTrue("超限编码结果仍须可解析，实际 $parsed", parsed is LocationCodec.Parsed.PageInk)
        assertEquals(LocationCodec.MAX_INK_POINTS, (parsed as LocationCodec.Parsed.PageInk).points.size)
    }

    /** 生成 `page:1;ink:<color>,<w>,x,y,...` 形式的 location，坐标点数由 [pointCount] 指定。 */
    private fun inkLocation(pointCount: Int): String =
        "page:1;ink:ff0000,1.50," +
            (0 until pointCount).joinToString(",") { "1.00,2.00" }
}
