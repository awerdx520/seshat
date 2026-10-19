package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [PdfTocEntries] 的单测（纯 JVM，无 Robolectric，不 import pdfbox）。
 *
 * 守的不变量：
 * - 有 outline 时条目 = 拍平结果（数量/顺序/缩进与树一致），**不做**页码目录混入；
 * - outline 缺失时回退「第 N 页」页码目录（1-based 文案 + 0-based pageIndex）；
 * - 当前页高亮取「页码 <= 当前页的最后一项」（章节中间翻阅高亮本章），
 *   全部在之后时落到 0，空表返回 -1（调用方不回传 initialSelection）。
 */
class PdfTocEntriesTest {

    // ------------------------------------------------------------------ build

    @Test
    fun buildUsesFlattenedOutlineWhenPresent() {
        // 守：两层 outline → 条目数等于拍平数，depth 逐层 +1，顺序父先于子。
        val outline = listOf(
            PdfOutlineReader.PdfOutlineItem(
                "第一章", 0,
                listOf(
                    PdfOutlineReader.PdfOutlineItem("1.1 节", 1),
                    PdfOutlineReader.PdfOutlineItem(
                        "1.2 节", 2,
                        listOf(PdfOutlineReader.PdfOutlineItem("1.2.1 小节", 3)),
                    ),
                ),
            ),
            PdfOutlineReader.PdfOutlineItem("第二章", 4),
        )

        val entries = PdfTocEntries.build(outline, pageCount = 99)

        // pageCount 传 99：有 outline 时不得混入页码目录项
        assertEquals(5, entries.size)
        assertEquals(
            listOf("第一章", "1.1 节", "1.2 节", "1.2.1 小节", "第二章"),
            entries.map { it.title },
        )
        assertEquals(listOf(0, 1, 1, 2, 0), entries.map { it.depth })
        assertEquals(listOf(0, 1, 2, 3, 4), entries.map { it.pageIndex })
    }

    @Test
    fun buildFallsBackToPageDirectoryWhenOutlineEmpty() {
        // 守：无 outline → 3 页文档给出 3 条「第 N 页」，文案 1-based、pageIndex 0-based。
        val entries = PdfTocEntries.build(emptyList(), pageCount = 3)

        assertEquals(3, entries.size)
        assertTrue(entries[0].title.contains("第 1 页"))
        assertEquals(listOf(0, 1, 2), entries.map { it.pageIndex })
        assertEquals(listOf(0, 0, 0), entries.map { it.depth })
    }

    // ------------------------------------------------------------ indexForPage

    @Test
    fun indexForPagePicksLastEntryNotAfterCurrentPage() {
        // 守：第 7 页落在「0-5-10」的中间段 → 高亮页码 5 那一项（索引 1），不是下一章 10。
        val entries = entriesOf(0, 5, 10)

        assertEquals(1, PdfTocEntries.indexForPage(entries, currentPage = 7))
    }

    @Test
    fun indexForPageExactMatchPicksThatEntry() {
        // 守：正好落在某项页码上 → 就是该项（边界取等号）。
        val entries = entriesOf(0, 5, 10)

        assertEquals(1, PdfTocEntries.indexForPage(entries, currentPage = 5))
    }

    @Test
    fun indexForPageBeforeFirstEntryReturnsZero() {
        // 守：当前页在所有目录项之前（前置封面等）→ 落到第一项，不能返回 -1 之外的越界值。
        val entries = entriesOf(4, 9)

        assertEquals(0, PdfTocEntries.indexForPage(entries, currentPage = 1))
    }

    @Test
    fun indexForPageOnEmptyListReturnsMinusOne() {
        // 守：空表 → -1（调用方据此不传 initialSelection，避免高亮第 0 项）。
        assertEquals(-1, PdfTocEntries.indexForPage(emptyList(), currentPage = 3))
    }

    /** 按给定页码造条目（标题/depth 不参与定位逻辑）。 */
    private fun entriesOf(vararg pages: Int): List<PdfTocEntries.Entry> =
        pages.mapIndexed { i, page -> PdfTocEntries.Entry("项 $i", page, 0) }
}
