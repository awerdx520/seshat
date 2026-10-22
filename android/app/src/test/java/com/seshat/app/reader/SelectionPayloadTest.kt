package com.seshat.app.reader

import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [SelectionPayload] 的选区载荷解析单测（M10.3 T4）。
 *
 * 覆盖范围：
 * - 正常载荷（`{"s":12,"e":20,"t":"..."}` 经「一层 JSON 字符串」包裹后）的解析；
 * - 选中原文含分隔符 / 引号 / 反斜杠 / 换行 / 制表符 / emoji（JSON 转义承载，不截断不丢字）；
 * - 空选区、`null`、空串、缺字段、非数字、负数、倒序、零长度等**非法输入一律返回 null 且不抛异常**；
 * - 降级：`locationFor` 在无偏移时退回旧形态 `chapter-<n>`；
 * - 与 [LocationCodec] 的往返（`chapter:<i>@<s>-<e>` 可被 `parse` 解析回 `Chapter`）。
 *
 * 纯 JVM，无 Android 依赖（本仓库无 androidTest 目录，偏移解析只能在这里验证）。
 */
class SelectionPayloadTest {

    /** 模拟 `evaluateJavascript` 的返回值：脚本返回字符串时，回调值是「一层 JSON 字符串」。 */
    private fun jsReturn(payload: String): String =
        Json.encodeToString(JsonElement.serializer(), JsonPrimitive(payload))

    /** 拼一个合法的载荷文本（`t` 走 JSON 转义，测试文本含引号/反斜杠也无需手写转义）。 */
    private fun payload(start: Int, end: Int, text: String): String {
        val encodedText = Json.encodeToString(JsonElement.serializer(), JsonPrimitive(text))
        return """{"s":$start,"e":$end,"t":$encodedText}"""
    }

    // ---- 正常路径 ----

    @Test
    fun parseNormalPayload() {
        val raw = jsReturn(payload(12, 20, "选中文本"))
        assertEquals(SelectionRange(12, 20, "选中文本"), SelectionPayload.parse(raw))
    }

    @Test
    fun parseTextContainingSeparatorsAndEscapes() {
        // 选原文里带 location 分隔符（| @ - ; :）、引号、反斜杠、换行与制表符：
        // 用 JSON 承载后必须原样还原，不能被分隔符编码截断。
        val text = "a|b@c-d;e:f \"引号\" back\\slash\n第二行\ttab"
        val parsed = SelectionPayload.parse(jsReturn(payload(3, 3 + text.length, text)))
        assertEquals(SelectionRange(3, 3 + text.length, text), parsed)
    }

    @Test
    fun parseSurrogatePairTextKeepsUtf16Offsets() {
        // emoji 占 2 个 UTF-16 code unit：偏移与 Kotlin String.length 同口径
        val text = "a😀b"
        val parsed = SelectionPayload.parse(jsReturn(payload(100, 100 + text.length, text)))
        assertEquals(SelectionRange(100, 104, text), parsed)
    }

    @Test
    fun parseZeroStartOffset() {
        // 章首开始选（start = 0）是合法边界
        assertEquals(SelectionRange(0, 5, "开头五个"), SelectionPayload.parse(jsReturn(payload(0, 5, "开头五个"))))
    }

    @Test
    fun parseMissingTextFieldYieldsEmptyText() {
        // t 缺省：偏移仍可用于跳转，正文按空串处理（不因此判整条载荷无效）
        val raw = jsReturn("""{"s":1,"e":3}""")
        assertEquals(SelectionRange(1, 3, ""), SelectionPayload.parse(raw))
    }

    @Test
    fun parseNullTextFieldYieldsEmptyText() {
        // JsonNull 的 content 是字面量 "null"，必须用 contentOrNull —— 否则文本会变成四个字母
        val raw = jsReturn("""{"s":1,"e":3,"t":null}""")
        assertEquals(SelectionRange(1, 3, ""), SelectionPayload.parse(raw))
    }

    @Test
    fun parseDirectObjectPayloadAccepted() {
        // 兼容「直接返回对象文本」的实现（规范上会多包一层字符串）
        assertEquals(SelectionRange(7, 9, "直接"), SelectionPayload.parse(payload(7, 9, "直接")))
    }

    // ---- 空选区 ----

    @Test
    fun parseEmptySelectionReturnsNull() {
        // 新脚本在无选区/折叠选区时返回空串 → 回调值是 ""
        assertNull(SelectionPayload.parse(jsReturn("")))
    }

    @Test
    fun parseNullAndBlankReturnNull() {
        assertNull(SelectionPayload.parse(null))
        assertNull(SelectionPayload.parse(""))
        assertNull(SelectionPayload.parse("   "))
        assertNull(SelectionPayload.parse("null"))
    }

    @Test
    fun parseZeroLengthRangeReturnsNull() {
        // start == end 无法定位（encodeChapter 会产出 0 长度 location）
        assertNull(SelectionPayload.parse(jsReturn(payload(5, 5, ""))))
    }

    // ---- 非法输入 ----

    @Test
    fun parseStartGreaterThanEndReturnsNull() {
        assertNull(SelectionPayload.parse(jsReturn(payload(20, 12, "倒序"))))
    }

    @Test
    fun parseNegativeOffsetReturnsNull() {
        assertNull(SelectionPayload.parse(jsReturn(payload(-1, 5, "负数"))))
        assertNull(SelectionPayload.parse(jsReturn(payload(1, -5, "负数"))))
    }

    @Test
    fun parseMissingFieldsReturnNull() {
        assertNull(SelectionPayload.parse(jsReturn("""{"s":12,"t":"缺 end"}""")))
        assertNull(SelectionPayload.parse(jsReturn("""{"e":20,"t":"缺 start"}""")))
        assertNull(SelectionPayload.parse(jsReturn("""{}""")))
    }

    @Test
    fun parseNonNumericFieldsReturnNull() {
        assertNull(SelectionPayload.parse(jsReturn("""{"s":"12","e":"20","t":"字符串偏移"}""")))
        assertNull(SelectionPayload.parse(jsReturn("""{"s":1.5,"e":2,"t":"小数"}""")))
    }

    @Test
    fun parseMalformedInputReturnsNullWithoutThrowing() {
        // 半截 JSON / 非对象 / 非字符串字面量：一律 null，绝不抛异常
        assertNull(SelectionPayload.parse(jsReturn("不是 JSON")))
        assertNull(SelectionPayload.parse("\"{\\\"s\\\":12,"))
        assertNull(SelectionPayload.parse("[]"))
        assertNull(SelectionPayload.parse("123"))
        assertNull(SelectionPayload.parse("true"))
    }

    // ---- 降级与往返 ----

    @Test
    fun locationForEncodesChapterWithOffsets() {
        assertEquals(
            "chapter:3@12-20",
            SelectionPayload.locationFor(3, SelectionRange(12, 20, "选中文本")),
        )
    }

    @Test
    fun locationForWithoutRangeFallsBackToLegacyChapterForm() {
        // 旧 WebView / JS 失败：退回 `chapter-<n>`，与 EpubSyncMapper.location 的兜底形态一致
        assertEquals("chapter-7", SelectionPayload.locationFor(7, null))
    }

    @Test
    fun locationForRoundTripsThroughLocationCodec() {
        val parsed = SelectionPayload.parse(jsReturn(payload(30, 45, "往返文本")))
        val location = SelectionPayload.locationFor(2, parsed)
        assertEquals("chapter:2@30-45", location)
        assertEquals(LocationCodec.Parsed.Chapter(2, 30, 45), LocationCodec.parse(location))
    }

    @Test
    fun locationFromPayloadIsNeverUnknown() {
        // 编码闭合性：任何能解析出偏移的载荷，其 location 必可被 LocationCodec 重新解析
        val samples = listOf(
            payload(0, 1, "a"),
            payload(999, 1000, "长偏移"),
            payload(12, 20, "含|@-;分隔符"),
        )
        for (sample in samples) {
            val range = SelectionPayload.parse(jsReturn(sample))
            val location = SelectionPayload.locationFor(0, range)
            assertEquals(true, LocationCodec.parse(location) is LocationCodec.Parsed.Chapter)
        }
    }
}
