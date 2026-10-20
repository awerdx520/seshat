package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PdfBookmarkStore] 的持久化行为单测（M10.10）。
 *
 * 用内存 Map 注入读写函数（与 [PdfInkStoreTest] 一致），因此无需 Android 环境即可在 JVM 上验证。
 */
class PdfBookmarkStoreTest {

    /** 模拟 SharedPreferences 的键值存储。 */
    private val prefs = mutableMapOf<String, String>()

    /** 被测对象：读写直接落到 [prefs]。 */
    private val store = PdfBookmarkStore(
        read = { key -> prefs[key] },
        write = { key, value -> prefs[key] = value },
    )

    /** 构造一条书签。 */
    private fun bookmark(page: Int) =
        PdfBookmark(page = page, title = "第 ${page + 1} 页", createdAt = 1_700_000_000_000L + page)

    @Test
    fun listReturnsSortedBookmarks() {
        // 故意以乱序写入（模拟历史数据），读出必须按页升序
        store.add("d", bookmark(8))
        store.add("d", bookmark(2))
        store.add("d", bookmark(5))

        assertEquals(3, store.list("d").size)
        assertEquals(listOf(2, 5, 8), store.list("d").map { it.page })
        // 标题与创建时间也完整往返
        assertEquals("第 3 页", store.list("d").first().title)
        assertEquals(1_700_000_000_002L, store.list("d").first().createdAt)
    }

    @Test
    fun addPersistsAndDedupes() {
        assertTrue(store.add("d", bookmark(3)))
        // 同页二次添加：不重复写
        assertFalse(store.add("d", bookmark(3)))

        val stored = store.list("d")
        assertEquals(1, stored.size)
        assertEquals(3, stored.single().page)
        assertTrue(store.has("d", 3))
        // 落盘 JSON 中也只有一条（重新解码后 size 仍为 1）
        assertEquals(1, store.list("d").size)
    }

    @Test
    fun removePersists() {
        store.add("d", bookmark(1))
        store.add("d", bookmark(6))

        store.remove("d", 1)

        assertEquals(listOf(6), store.list("d").map { it.page })
        assertFalse(store.has("d", 1))
        assertTrue(store.has("d", 6))
    }

    @Test
    fun removeLastWritesEmptyList() {
        store.add("d", bookmark(2))

        store.remove("d", 2)

        // 移除最后一条后必须写回空表（避免旧书签残留在 prefs 里被后续读到）
        assertTrue(store.list("d").isEmpty())
        val raw = prefs[PdfBookmarkStore.key("d")]
        assertTrue("应写回空书签表：$raw", raw != null && raw.contains("\"bookmarks\":[]"))
    }

    @Test
    fun corruptJsonReturnsEmpty() {
        // 损坏的 JSON 不得抛异常，按空表处理
        prefs[PdfBookmarkStore.key("d")] = "{not json"

        assertTrue(store.list("d").isEmpty())
        assertFalse(store.has("d", 0))
    }
}
