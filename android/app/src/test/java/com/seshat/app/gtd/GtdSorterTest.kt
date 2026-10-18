package com.seshat.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [GtdSorter] 的纯 JVM 单测（不依赖 Android 框架）。 */
class GtdSorterTest {

    private fun entry(
        title: String,
        scheduled: String? = null,
        deadline: String? = null,
    ): OrgEntry = OrgEntry(
        level = 1,
        title = title,
        todoState = null,
        priority = null,
        tags = emptyList(),
        scheduled = scheduled,
        deadline = deadline,
        body = "",
    )

    // ---------- datePrefix ----------

    @Test
    fun datePrefix_angleBracketWithoutTime() {
        assertEquals("2026-10-20", GtdSorter.datePrefix("<2026-10-20 Tue>"))
    }

    @Test
    fun datePrefix_angleBracketWithTime() {
        assertEquals("2026-10-20", GtdSorter.datePrefix("<2026-10-20 Tue 10:00>"))
    }

    @Test
    fun datePrefix_surroundingWhitespaceIsTrimmed() {
        assertEquals("2026-10-20", GtdSorter.datePrefix("   <2026-10-20 Tue>  "))
    }

    @Test
    fun datePrefix_withoutAngleBrackets() {
        assertEquals("2026-10-20", GtdSorter.datePrefix("2026-10-20"))
    }

    @Test
    fun datePrefix_nonZeroPaddedMonth_returnsNull() {
        // 规格要求 `\d{4}-\d{2}-\d{2}`：`2026-1-5` 非零填充，解析失败 → null。
        assertNull(GtdSorter.datePrefix("  <2026-1-5> "))
    }

    @Test
    fun datePrefix_nullOrEmptyOrIllegal_returnsNull() {
        assertNull(GtdSorter.datePrefix(null))
        assertNull(GtdSorter.datePrefix("<>"))
        assertNull(GtdSorter.datePrefix(""))
        assertNull(GtdSorter.datePrefix("<not a date>"))
        assertNull(GtdSorter.datePrefix("<2026-13-01 Wed>")) // 月份越界
    }

    // ---------- byScheduled ----------

    @Test
    fun byScheduled_sortsAscendingWithUndatedLast() {
        val input = listOf(
            entry("no-date"),
            entry("late", scheduled = "<2026-11-01 Sun>"),
            entry("early", scheduled = "<2026-10-20 Tue>"),
        )

        assertEquals(
            listOf("early", "late", "no-date"),
            GtdSorter.byScheduled(input).map { it.title },
        )
    }

    @Test
    fun byScheduled_isStableForEqualKeys() {
        val input = listOf(
            entry("first", scheduled = "<2026-10-20 Tue>"),
            entry("second", scheduled = "<2026-10-20 Tue 10:00>"),
            entry("third", scheduled = "<2026-10-21 Wed>"),
        )

        assertEquals(
            listOf("first", "second", "third"),
            GtdSorter.byScheduled(input).map { it.title },
        )
    }

    @Test
    fun byScheduled_doesNotMutateInputOrder() {
        val input = listOf(
            entry("b", scheduled = "<2026-11-01 Sun>"),
            entry("a", scheduled = "<2026-10-20 Tue>"),
        )

        GtdSorter.byScheduled(input)

        assertEquals(listOf("b", "a"), input.map { it.title })
    }

    // ---------- byDeadline ----------

    @Test
    fun byDeadline_sortsAscendingWithUndatedLast() {
        val input = listOf(
            entry("no-deadline"),
            entry("late", deadline = "<2026-12-31 Thu>"),
            entry("early", deadline = "<2026-10-20 Tue>"),
        )

        assertEquals(
            listOf("early", "late", "no-deadline"),
            GtdSorter.byDeadline(input).map { it.title },
        )
    }

    @Test
    fun byDeadline_isStableForEqualKeys() {
        val input = listOf(
            entry("first", deadline = "<2026-10-20 Tue>"),
            entry("second", deadline = "<2026-10-20 Tue>"),
            entry("third", deadline = "<2026-10-21 Wed>"),
        )

        assertEquals(
            listOf("first", "second", "third"),
            GtdSorter.byDeadline(input).map { it.title },
        )
    }

    // ---------- byEarliestDate ----------

    @Test
    fun byEarliestDate_usesEarlierOfScheduledAndDeadline() {
        val input = listOf(
            // 最早日期 2026-10-25（deadline）
            entry("only-late-deadline", deadline = "<2026-10-25 Sun>"),
            // 最早日期 2026-10-20（scheduled 早于自身 deadline）
            entry("early-scheduled", scheduled = "<2026-10-20 Tue>", deadline = "<2026-11-01 Sun>"),
            // 最早日期 2026-10-22（scheduled）
            entry("mid-scheduled", scheduled = "<2026-10-22 Thu>"),
        )

        assertEquals(
            listOf("early-scheduled", "mid-scheduled", "only-late-deadline"),
            GtdSorter.byEarliestDate(input).map { it.title },
        )
    }

    @Test
    fun byEarliestDate_entriesWithoutAnyDateGoLast() {
        val input = listOf(
            entry("none-1"),
            entry("dated", scheduled = "<2026-10-20 Tue>"),
            entry("none-2"),
        )

        assertEquals(
            listOf("dated", "none-1", "none-2"),
            GtdSorter.byEarliestDate(input).map { it.title },
        )
    }

    @Test
    fun byEarliestDate_emptyInput_returnsEmpty() {
        assertEquals(emptyList<OrgEntry>(), GtdSorter.byEarliestDate(emptyList()))
    }
}
