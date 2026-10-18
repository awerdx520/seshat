package com.seshat.app.reader

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** 书架纯逻辑（进度百分比 / 过滤 / 排序）单测。 */
class BookShelfLogicTest {

    // ---- progressPercent ----

    @Test
    fun progressPercentHandlesBoundaries() {
        assertEquals(0, BookShelfLogic.progressPercent(0, 10))
        assertEquals(50, BookShelfLogic.progressPercent(5, 10))
        assertEquals(100, BookShelfLogic.progressPercent(10, 10))
    }

    @Test
    fun progressPercentClampsNegativeCurrentToZero() {
        assertEquals(0, BookShelfLogic.progressPercent(-1, 10))
    }

    @Test
    fun progressPercentClampsOverflowToHundred() {
        assertEquals(100, BookShelfLogic.progressPercent(20, 10))
    }

    @Test
    fun progressPercentReturnsZeroForNonPositiveTotal() {
        assertEquals(0, BookShelfLogic.progressPercent(5, 0))
        assertEquals(0, BookShelfLogic.progressPercent(5, -3))
    }

    @Test
    fun progressPercentTruncatesRemainder() {
        // 1/3 → 33（向下取整，不四舍五入）
        assertEquals(33, BookShelfLogic.progressPercent(1, 3))
    }

    // ---- matches ----

    @Test
    fun allMatchesEveryPercent() {
        listOf(0, 50, 100).forEach { percent ->
            assertTrue("ALL 应恒真（$percent）", BookShelfLogic.matches(BookFilter.ALL, percent))
        }
    }

    @Test
    fun unreadMatchesOnlyZero() {
        assertTrue(BookShelfLogic.matches(BookFilter.UNREAD, 0))
        assertFalse(BookShelfLogic.matches(BookFilter.UNREAD, 50))
        assertFalse(BookShelfLogic.matches(BookFilter.UNREAD, 100))
    }

    @Test
    fun readingMatchesOnlyInBetween() {
        assertFalse(BookShelfLogic.matches(BookFilter.READING, 0))
        assertTrue(BookShelfLogic.matches(BookFilter.READING, 50))
        assertFalse(BookShelfLogic.matches(BookFilter.READING, 100))
    }

    @Test
    fun finishedMatchesOnlyHundred() {
        assertFalse(BookShelfLogic.matches(BookFilter.FINISHED, 0))
        assertFalse(BookShelfLogic.matches(BookFilter.FINISHED, 50))
        assertTrue(BookShelfLogic.matches(BookFilter.FINISHED, 100))
    }

    // ---- sort ----

    @Test
    fun recentSortsByLastReadAtDescending() {
        val items = listOf(
            item(title = "旧", lastReadAt = 100L),
            item(title = "新", lastReadAt = 300L),
            item(title = "中", lastReadAt = 200L),
        )

        assertEquals(
            listOf("新", "中", "旧"),
            BookShelfLogic.sort(BookSort.RECENT, items).map { it.title },
        )
    }

    @Test
    fun recentFallsBackToTitleWhenLastReadAtEqual() {
        val items = listOf(
            item(title = "B书", lastReadAt = 100L),
            item(title = "A书", lastReadAt = 100L),
        )

        assertEquals(
            listOf("A书", "B书"),
            BookShelfLogic.sort(BookSort.RECENT, items).map { it.title },
        )
    }

    @Test
    fun titleSortIgnoresCase() {
        val items = listOf(
            item(title = "beta"),
            item(title = "Alpha"),
            item(title = "gamma"),
        )

        assertEquals(
            listOf("Alpha", "beta", "gamma"),
            BookShelfLogic.sort(BookSort.TITLE, items).map { it.title },
        )
    }

    @Test
    fun importTimeSortsByImportedAtDescending() {
        val items = listOf(
            item(title = "先导入", importedAt = 1_000L),
            item(title = "后导入", importedAt = 9_000L),
            item(title = "中导入", importedAt = 5_000L),
        )

        assertEquals(
            listOf("后导入", "中导入", "先导入"),
            BookShelfLogic.sort(BookSort.IMPORT_TIME, items).map { it.title },
        )
    }

    @Test
    fun sortDoesNotMutateInputList() {
        val items = listOf(
            item(title = "B", importedAt = 1L),
            item(title = "A", importedAt = 2L),
        )
        val snapshot = items.toList()

        val sorted = BookShelfLogic.sort(BookSort.IMPORT_TIME, items)

        assertEquals("原表顺序不应被就地修改", snapshot, items)
        assertEquals(listOf("A", "B"), sorted.map { it.title })
    }

    /** 构造测试用条目（默认值让每个用例只关心相关字段）。 */
    private fun item(
        title: String,
        percent: Int = 0,
        lastReadAt: Long = 0L,
        importedAt: Long = 0L,
    ): BookItem = BookItem(
        file = File(title),
        type = BookType.EPUB,
        title = title,
        author = null,
        totalCount = 10,
        progressKey = title,
        percent = percent,
        lastReadAt = lastReadAt,
        importedAt = importedAt,
    )
}
