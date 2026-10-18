package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * [TocItemText] 的纯 JVM 单测（无 Android 依赖）。
 *
 * 覆盖目录对话框条目文案的三类语义：
 * 1. 序号为 **1-based**（读者视角），且与 `chapters` 顺序（spine 顺序）一致；
 * 2. 标题可用时原样使用（仅去首尾空白），不可用（空串 / 全空白）时回退到传入的占位文案；
 * 3. 空章节列表 → 空列表（调用方据此显示「本书没有目录」并提前返回）。
 */
class TocItemTextTest {

    private val missing = "（无标题）"

    @Test
    fun labelsUseOneBasedIndexWithTitle() {
        val chapters = listOf(
            EpubChapter(index = 0, title = "序章", href = "a.xhtml"),
            EpubChapter(index = 1, title = "第一章 起", href = "b.xhtml"),
        )
        assertEquals(
            listOf("1. 序章", "2. 第一章 起"),
            TocItemText.labels(chapters, missing),
        )
    }

    @Test
    fun labelsUseMissingLabelWhenTitleIsBlank() {
        val chapters = listOf(
            EpubChapter(index = 0, title = "", href = "a.xhtml"),
            EpubChapter(index = 1, title = "   \t", href = "b.xhtml"),
            EpubChapter(index = 2, title = "第三章", href = "c.xhtml"),
        )
        assertEquals(
            listOf("1. $missing", "2. $missing", "3. 第三章"),
            TocItemText.labels(chapters, missing),
        )
    }

    @Test
    fun labelsTrimTitleWhitespace() {
        val chapters = listOf(EpubChapter(index = 0, title = "  第二章\n", href = "b.xhtml"))
        assertEquals(listOf("1. 第二章"), TocItemText.labels(chapters, missing))
    }

    @Test
    fun labelsAreEmptyForEmptyChapterList() {
        assertEquals(emptyList<String>(), TocItemText.labels(emptyList(), missing))
    }
}
