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
}
