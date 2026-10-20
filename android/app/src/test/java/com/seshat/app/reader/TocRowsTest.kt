package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [TocRows] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：href → 章节索引的命中/未命中语义（未命中必须 -1，不可跳转）、
 * 容器节点占位标题、depth 随嵌套递增、id 的全局唯一性（兄弟序号路径而非 href），
 * 以及 PDF 的 pageIndex 透传（-1 保留）。
 */
class TocRowsTest {

    /** 三章书：href 均为「epub 根相对路径」，可直接与 TocNode.href 比较。 */
    private val chapters = listOf(
        EpubChapter(0, "第一章", "OEBPS/text/ch1.xhtml"),
        EpubChapter(1, "第二章", "OEBPS/text/ch2.xhtml"),
        EpubChapter(2, "第三章", "OEBPS/text/ch3.xhtml"),
    )

    private val untitled = "未命名章节"

    @Test
    fun forEpubMatchesHrefToChapterIndex() {
        // href 与 chapters[i].href 精确相等 → targetIndex 必须是该章节的下标。
        val tree = listOf(
            TocNode(title = "第一章", href = "OEBPS/text/ch1.xhtml"),
            TocNode(title = "第二章", href = "OEBPS/text/ch2.xhtml"),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals(2, rows.size)
        assertEquals(0, rows[0].targetIndex)
        assertEquals(1, rows[1].targetIndex)
    }

    @Test
    fun forEpubUnmatchedHrefIsNotTappable() {
        // 锚点型/失效 href 找不到章节 → -1（不可跳转），且不能影响子节点标记。
        val tree = listOf(
            TocNode(title = "锚点", href = "OEBPS/text/ch1.xhtml#sec2"),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals(-1, rows[0].targetIndex)
        assertEquals(false, rows[0].hasChildren)
        assertEquals("锚点", rows[0].title)
    }

    @Test
    fun forEpubContainerNodeWithoutAnchorIsNotTappable() {
        // 容器节点（<li> 内无 <a>）：href 为 null、无标题 → 占位文案 + 不可跳转 + 有子节点。
        val tree = listOf(
            TocNode(
                title = "",
                href = null,
                children = listOf(TocNode(title = "第一章", href = "OEBPS/text/ch1.xhtml")),
            ),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals(untitled, rows[0].title)
        assertEquals(-1, rows[0].targetIndex)
        assertTrue(rows[0].hasChildren)
    }

    @Test
    fun forEpubDepthIncreasesWithNesting() {
        // 两层树：根 depth 0、子节点 depth 1（渲染时据此缩进 16dp）。
        val tree = listOf(
            TocNode(
                title = "第一卷",
                children = listOf(TocNode(title = "第一章", href = "OEBPS/text/ch1.xhtml")),
            ),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals(2, rows.size)
        assertEquals(0, rows[0].depth)
        assertEquals(1, rows[1].depth)
    }

    @Test
    fun forEpubIdsAreUniqueAcrossSiblings() {
        // 关键不变量：两个同标题、同 href(null) 的容器兄弟，不能用 href 当 id——必须互不相同，
        // 否则展开一个会连带展开另一个。
        val tree = listOf(
            TocNode(title = "上卷", href = null),
            TocNode(title = "上卷", href = null),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals(2, rows.size)
        assertNotEquals(rows[0].id, rows[1].id)
    }

    @Test
    fun forEpubIdsAreDfsPaths() {
        // id 是 DFS 兄弟序号路径：第二层第一个子节点为 "0/0"（根为 "0"）。
        val tree = listOf(
            TocNode(
                title = "第一卷",
                children = listOf(
                    TocNode(title = "第一章", href = "OEBPS/text/ch1.xhtml"),
                    TocNode(title = "第二章", href = "OEBPS/text/ch2.xhtml"),
                ),
            ),
        )

        val rows = TocRows.forEpub(tree, chapters, untitled)

        assertEquals("0", rows[0].id)
        assertEquals("0/0", rows[1].id)
        assertEquals("0/1", rows[2].id)
    }

    @Test
    fun forEpubEmptyTreeReturnsEmpty() {
        // nav 缺失且 NCX 也解析不出内容时为空树 → 空行表（调用方据此回退扁平章节）。
        assertEquals(emptyList<TocRow>(), TocRows.forEpub(emptyList(), chapters, untitled))
    }

    @Test
    fun forEpubFlatMapsEveryChapter() {
        // 回退模式：每章一行、targetIndex 即章节下标、depth 全 0、id 唯一。
        val rows = TocRows.forEpubFlat(chapters, untitled)

        assertEquals(3, rows.size)
        assertEquals(listOf(0, 1, 2), rows.map { it.targetIndex })
        assertTrue(rows.all { it.depth == 0 })
        assertTrue(rows.none { it.hasChildren })
        assertEquals(3, rows.map { it.id }.toSet().size)
    }

    @Test
    fun forEpubFlatUsesMissingTitleForBlankChapterTitle() {
        // 章节标题为空（buildChapters 回退失败）时用占位文案，避免抽屉里出现空行。
        val rows = TocRows.forEpubFlat(listOf(EpubChapter(0, "  ", "text/ch1.xhtml")), untitled)

        assertEquals(1, rows.size)
        assertEquals(untitled, rows[0].title)
    }

    @Test
    fun forPdfMapsPageIndex() {
        // PDF 书签树的 pageIndex 直接透传为 targetIndex（两层结构，子书签页码独立）。
        val tree = listOf(
            PdfOutlineReader.PdfOutlineItem(
                title = "第一章",
                pageIndex = 0,
                children = listOf(PdfOutlineReader.PdfOutlineItem(title = "1.1", pageIndex = 3)),
            ),
            PdfOutlineReader.PdfOutlineItem(title = "第二章", pageIndex = 10),
        )

        val rows = TocRows.forPdf(tree)

        assertEquals(3, rows.size)
        assertEquals(0, rows[0].targetIndex)
        assertEquals(3, rows[1].targetIndex)
        assertEquals(1, rows[1].depth)
        assertEquals(10, rows[2].targetIndex)
    }

    @Test
    fun forPdfUnresolvedPageStaysMinusOne() {
        // 无页目标的纯链接书签（pageIndex = -1）必须原样保留 -1，不能被归一化成 0 跳首页。
        val tree = listOf(PdfOutlineReader.PdfOutlineItem(title = "外部链接", pageIndex = -1))

        val rows = TocRows.forPdf(tree)

        assertEquals(1, rows.size)
        assertEquals(-1, rows[0].targetIndex)
    }
}
