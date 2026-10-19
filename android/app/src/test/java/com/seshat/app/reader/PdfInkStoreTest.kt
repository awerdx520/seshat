package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PdfInkStore] 的持久化行为单测。
 *
 * 用内存 Map 注入读写函数，因此无需 Android 环境即可在 JVM 上验证全部逻辑。
 */
class PdfInkStoreTest {

    /** 模拟 SharedPreferences 的键值存储。 */
    private val prefs = mutableMapOf<String, String>()

    /** 被测对象：读写直接落到 [prefs]。 */
    private val store = PdfInkStore(
        read = { key -> prefs[key] },
        write = { key, value -> prefs[key] = value },
    )

    /** 一笔示例笔迹（红色、归一化线宽 0.004）。 */
    private fun stroke() = InkStroke(
        color = 0xFFE53935.toInt(),
        width = 0.004f,
        points = listOf(InkPoint(0.1f, 0.1f), InkPoint(0.9f, 0.9f)),
    )

    @Test
    fun emptyStoreHasNoStrokes() {
        assertTrue(store.strokes("d", 0).isEmpty())
        assertEquals(0, store.count("d"))
    }

    @Test
    fun appendStrokeIsStored() {
        store.appendStroke("d", 0, stroke())
        assertEquals(1, store.strokes("d", 0).size)
        assertEquals(1, store.count("d"))
    }

    @Test
    fun twoStrokesKeepOrder() {
        // 两笔的点序列不同，用于验证顺序为追加顺序（后追加在末尾）
        val first = stroke()
        val second = stroke().copy(points = listOf(InkPoint(0.2f, 0.2f), InkPoint(0.3f, 0.3f)))
        store.appendStroke("d", 0, first)
        store.appendStroke("d", 0, second)

        val strokes = store.strokes("d", 0)
        assertEquals(2, store.count("d"))
        assertEquals(first, strokes[0])
        assertEquals(second, strokes[1])
    }

    @Test
    fun pagesAreIsolated() {
        store.appendStroke("d", 0, stroke())
        store.appendStroke("d", 1, stroke())
        store.appendStroke("d", 1, stroke())

        assertEquals(1, store.strokes("d", 0).size)
        assertEquals(2, store.strokes("d", 1).size)
        assertEquals(3, store.count("d"))
    }

    @Test
    fun undoLastRemovesLastStroke() {
        store.appendStroke("d", 0, stroke())
        store.appendStroke("d", 0, stroke())

        assertTrue(store.undoLast("d", 0))
        assertEquals(1, store.count("d"))
    }

    @Test
    fun undoLastOnEmptyPageReturnsFalse() {
        // 该页从未有笔迹
        assertFalse(store.undoLast("d", 0))
        assertEquals(0, store.count("d"))
    }

    @Test
    fun clearPageEmptiesOnlyThatPage() {
        store.appendStroke("d", 0, stroke())
        store.appendStroke("d", 1, stroke())

        store.clearPage("d", 0)

        assertFalse(store.hasInk("d", 0))
        assertTrue(store.hasInk("d", 1))
        assertEquals(1, store.count("d"))
    }

    @Test
    fun hasInkReflectsState() {
        assertFalse(store.hasInk("d", 0))
        store.appendStroke("d", 0, stroke())
        assertTrue(store.hasInk("d", 0))
        assertFalse(store.hasInk("d", 1))
    }

    @Test
    fun corruptedJsonReturnsEmptyDocument() {
        // 损坏的 JSON 不得抛异常，按空文档处理
        prefs[PdfInkStore.key("d")] = "{not-json"

        assertTrue(store.strokes("d", 0).isEmpty())
        assertEquals(0, store.count("d"))
        assertEquals("d", store.document("d").documentId)
    }

    @Test
    fun keyUsesDocumentId() {
        assertEquals("pdf_ink_abc", PdfInkStore.key("abc"))
    }

    @Test
    fun appendUpdatesTimestamp() {
        store.appendStroke("d", 0, stroke())
        assertTrue(store.document("d").updatedAt > 0L)
    }

    @Test
    fun prefsNameIsSharedPdfFile() {
        // 与 PdfAnnotationStore / PdfProgressStore 共用 prefs 文件，靠键前缀隔离
        assertEquals("pdf_reader", PdfInkStore.PREFS_NAME)
    }

    @Test
    fun clearLegacyStripsPrefixBeforeJudging() {
        val hex = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
        val uid = "0123456789ABCDEFGHJKMNPQRS"
        val uri = "content://media/external/document/7"
        val map = mutableMapOf(
            PdfInkStore.key(hex) to "{}",
            PdfInkStore.key(uri) to "{}",
            PdfInkStore.key(uid) to "{}",
            PdfInkStore.key("d") to "{}",
            // 其它 store 前缀的旧键不归本 store 管
            PdfProgressStore.key(hex) to "1:1",
        )
        val legacyAwareStore = PdfInkStore(
            read = { map[it] },
            write = { k, v -> map[k] = v },
            keys = { map.keys.toSet() },
            remove = { map.remove(it) },
        )

        assertEquals(2, legacyAwareStore.clearLegacy())

        assertFalse(map.containsKey(PdfInkStore.key(hex)))
        assertFalse(map.containsKey(PdfInkStore.key(uri)))
        assertTrue(map.containsKey(PdfInkStore.key(uid)))
        assertTrue(map.containsKey(PdfInkStore.key("d")))
        assertTrue(map.containsKey(PdfProgressStore.key(hex)))
    }

    // ---- M10.8 笔型字段与向后兼容 ----

    /** 旧版（M10.5）写入的 JSON：没有 `style` 字段。 */
    private fun legacyJson(docId: String): String =
        """{"documentId":"$docId","pages":[{"page":0,"strokes":[{"color":-1744387,"width":0.004,"points":[{"x":0.1,"y":0.2},{"x":0.2,"y":0.3}]}]}],"updatedAt":0}"""

    @Test
    fun legacyJsonWithoutStyleDecodesAsPen() {
        // 老用户数据无 style 字段，反序列化必须落为默认 PEN（无需迁移）
        prefs[PdfInkStore.key("doc1")] = legacyJson("doc1")

        val strokes = store.strokes("doc1", 0)
        assertEquals(1, strokes.size)
        assertEquals(InkStyle.PEN, strokes.single().style)
        // 旧字段本身仍按原样读出
        assertEquals(-1744387, strokes.single().color)
        assertEquals(0.004f, strokes.single().width, 0f)
        assertEquals(2, strokes.single().points.size)
    }

    @Test
    fun newStrokeKeepsItsStyle() {
        store.appendStroke("d", 0, stroke().copy(style = InkStyle.MARKER))

        // 重新从 prefs 解码（document() 每次都重新读），确认 style 真的落盘
        assertEquals(InkStyle.MARKER, store.document("d").pages.single().strokes.single().style)
        assertEquals(InkStyle.MARKER, store.strokes("d", 0).single().style)
    }

    @Test
    fun unknownStyleInJsonFallsBackToPen() {
        // 未知笔型（如未来新增）不得抛异常，coerceInputValues 回退到字段默认值
        prefs[PdfInkStore.key("d")] = """{"documentId":"d","pages":[{"page":0,"strokes":[
            {"color":-1,"width":0.01,"points":[{"x":0.1,"y":0.2},{"x":0.3,"y":0.4}],"style":"FOUNTAIN"}
        ]}],"updatedAt":0}"""

        val strokes = store.strokes("d", 0)
        assertEquals(1, strokes.size)
        assertEquals(InkStyle.PEN, strokes.single().style)
    }

    @Test
    fun encodedJsonContainsStyle() {
        store.appendStroke("d", 0, stroke().copy(style = InkStyle.MARKER))

        val raw = prefs[PdfInkStore.key("d")]
        assertTrue("原始 JSON 应含笔型：$raw", raw!!.contains("\"style\":\"MARKER\""))
    }

    @Test
    fun defaultStyleIsPen() {
        val plain = InkStroke(
            color = 0xFF000000.toInt(),
            width = 0.002f,
            points = listOf(InkPoint(0f, 0f), InkPoint(1f, 1f)),
        )
        assertEquals(InkStyle.PEN, plain.style)
    }
}
