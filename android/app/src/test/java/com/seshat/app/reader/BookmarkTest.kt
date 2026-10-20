package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [Bookmarks] 纯函数行为单测（M10.10）。
 *
 * `Bookmarks` 不依赖 Android，也不触碰 prefs，因此可直接在 JVM 上验证集合语义。
 */
class BookmarkTest {

    /** 构造一条书签（页索引 + 标题，创建时间固定）。 */
    private fun bookmark(page: Int, title: String = "第 ${page + 1} 页") =
        PdfBookmark(page = page, title = title, createdAt = 1_700_000_000_000L + page)

    @Test
    fun addAppendsAndSorts() {
        // 乱序加入 3 页 → 结果按页升序（与目录同序）
        var items = emptyList<PdfBookmark>()
        var added = false

        listOf(bookmark(5), bookmark(1), bookmark(3)).forEach { candidate ->
            val (updated, ok) = Bookmarks.add(items, candidate)
            items = updated
            added = ok
        }

        assertEquals(3, items.size)
        assertTrue(added)
        assertEquals(listOf(1, 3, 5), items.map { it.page })
    }

    @Test
    fun addRejectsDuplicatePage() {
        val first = bookmark(2)
        val (afterFirst, firstAdded) = Bookmarks.add(emptyList(), first)
        assertTrue(firstAdded)

        // 同页二次添加（标题不同也算重复，页是唯一键）
        val (afterSecond, secondAdded) = Bookmarks.add(afterFirst, first.copy(title = "别的标题"))

        assertFalse(secondAdded)
        assertEquals(afterFirst, afterSecond)
        assertEquals(1, afterSecond.size)
        assertEquals("第 3 页", afterSecond.single().title)
    }

    @Test
    fun addDoesNotMutateInput() {
        val input = listOf(bookmark(4), bookmark(2))
        val snapshot = input.toList()

        val (updated, added) = Bookmarks.add(input, bookmark(0))

        assertTrue(added)
        // 入参长度与内容均不变
        assertEquals(2, input.size)
        assertEquals(snapshot, input)
        // 返回的是新列表
        assertEquals(listOf(0, 2, 4), updated.map { it.page })
        assertEquals(input, snapshot)
    }

    @Test
    fun removeDropsOnlyThatPage() {
        val items = listOf(bookmark(1), bookmark(2), bookmark(3))

        val remaining = Bookmarks.remove(items, 2)

        assertEquals(listOf(1, 3), remaining.map { it.page })
        // 入参不受影响
        assertEquals(3, items.size)
    }

    @Test
    fun removeMissingPageIsNoOp() {
        val items = listOf(bookmark(1), bookmark(3))

        val remaining = Bookmarks.remove(items, 2)

        // 内容等值不变（同 size 且同顺序）
        assertEquals(2, remaining.size)
        assertEquals(items, remaining)
    }

    @Test
    fun hasReportsCorrectly() {
        val items = listOf(bookmark(0), bookmark(7))

        assertTrue(Bookmarks.has(items, 0))
        assertTrue(Bookmarks.has(items, 7))
        assertFalse(Bookmarks.has(items, 3))
        assertFalse(Bookmarks.has(emptyList(), 0))
    }

    @Test
    fun sortedOrdersByPage() {
        val shuffled = listOf(bookmark(9), bookmark(0), bookmark(4), bookmark(14))

        val ordered = Bookmarks.sorted(shuffled)

        assertEquals(listOf(0, 4, 9, 14), ordered.map { it.page })
        // 排序不修改入参
        assertEquals(9, shuffled.first().page)
    }
}
