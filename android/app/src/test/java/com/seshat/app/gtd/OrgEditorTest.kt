package com.seshat.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [OrgEditor] 改写逻辑的纯 JVM 单测（不依赖 Android 框架）。
 *
 * 覆盖：headlineLineOf 定位、toggleTodoState 四种分支（TODO→DONE、DONE→TODO、无状态→TODO、
 * 清除为 null）、setTodoState 按行号改写，以及「改写不破坏其他行 / 优先级 / 标签 / body」。
 */
class OrgEditorTest {

    /** 多层级 + 正文 + 优先级 + 标签的样例（行号即 list 索引）。 */
    private val source = listOf(
        "#+TITLE: demo",
        "#+FILETAGS: :notes:",
        "",
        "* 项目",
        "** TODO [#A] 实现 GTD 视图 :android:feature:",
        "   DEADLINE: <2026-10-20 Tue>",
        "   正文说明。",
        "** DONE [#B] 实现解析器 :core:",
        "* 个人",
        "** 阅读《第一性原理》 :reading:",
    ).joinToString("\n")

    private fun lines(text: String): List<String> = text.split("\n")

    // ---------- headlineLineOf 定位 ----------

    @Test
    fun headlineLineOf_mapsEachEntryToItsHeadlineLine() {
        assertEquals(3, OrgEditor.headlineLineOf(source, 0))
        assertEquals(4, OrgEditor.headlineLineOf(source, 1))
        assertEquals(7, OrgEditor.headlineLineOf(source, 2))
        assertEquals(8, OrgEditor.headlineLineOf(source, 3))
        assertEquals(9, OrgEditor.headlineLineOf(source, 4))
    }

    @Test
    fun headlineLineOf_agreesWithParserEntryCount() {
        val count = OrgParser().parse(source).entries.size
        assertEquals(5, count)
        // 每个条目都能定位（不抛异常）
        for (i in 0 until count) {
            OrgEditor.headlineLineOf(source, i)
        }
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.headlineLineOf(source, count)
        }
    }

    @Test
    fun headlineLineOf_ignoresNonHeadlineStarText() {
        // `**bold**` 星号后非空白，不能被识别为标题行
        val text = "* 真标题\n**bold** 强调文本\n** 第二个标题"
        assertEquals(0, OrgEditor.headlineLineOf(text, 0))
        assertEquals(2, OrgEditor.headlineLineOf(text, 1))
    }

    @Test
    fun headlineLineOf_negativeIndexThrows() {
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.headlineLineOf(source, -1)
        }
    }

    // ---------- toggleTodoState 各分支 ----------

    @Test
    fun toggleTodoState_todoToDone() {
        val result = OrgEditor.toggleTodoState(source, 1, "DONE")

        assertEquals("** DONE [#A] 实现 GTD 视图 :android:feature:", lines(result)[4])
        assertEquals(source.length, result.length)
    }

    @Test
    fun toggleTodoState_doneToTodo() {
        val result = OrgEditor.toggleTodoState(source, 2, "TODO")

        assertEquals("** TODO [#B] 实现解析器 :core:", lines(result)[7])
    }

    @Test
    fun toggleTodoState_noStateToTodo() {
        val result = OrgEditor.toggleTodoState(source, 4, "TODO")

        assertEquals("** TODO 阅读《第一性原理》 :reading:", lines(result)[9])
    }

    @Test
    fun toggleTodoState_clearToNull() {
        val result = OrgEditor.toggleTodoState(source, 2, null)

        // 仅剥离 TODO 关键字，优先级 [#B] 与标签保留
        assertEquals("** [#B] 实现解析器 :core:", lines(result)[7])
        assertNull(OrgParser().parse(result).entries[2].todoState)
    }

    @Test
    fun toggleTodoState_onlyTargetLineChanges() {
        val result = OrgEditor.toggleTodoState(source, 1, "DONE")

        val before = lines(source)
        val after = lines(result)
        assertEquals(before.size, after.size)
        for (i in before.indices) {
            if (i == 4) continue
            assertEquals("第 $i 行不应改变", before[i], after[i])
        }
    }

    @Test
    fun toggleTodoState_preservesPriorityTagsBodyAndLevel() {
        val parsed = OrgParser().parse(OrgEditor.toggleTodoState(source, 1, "DONE")).entries[1]

        assertEquals(2, parsed.level)
        assertEquals("实现 GTD 视图", parsed.title)
        assertEquals('A', parsed.priority)
        assertEquals(listOf("android", "feature"), parsed.tags)
        assertEquals("DONE", parsed.todoState)
        // body 与原文解析结果一致（DEADLINE + 正文未被触碰）
        assertEquals(OrgParser().parse(source).entries[1].body, parsed.body)
        assertEquals("2026-10-20 Tue", parsed.deadline)
    }

    @Test
    fun toggleTodoState_roundTripParsesNewState() {
        val done = OrgEditor.toggleTodoState(source, 1, "DONE")
        assertEquals("DONE", OrgParser().parse(done).entries[1].todoState)

        val back = OrgEditor.toggleTodoState(done, 1, "TODO")
        assertEquals("TODO", OrgParser().parse(back).entries[1].todoState)
        assertEquals(source, back)
    }

    // ---------- setTodoState 按行号 ----------

    @Test
    fun setTodoState_byLineIndexRewritesTodoKeyword() {
        val result = OrgEditor.setTodoState(source, 4, "DONE")

        assertEquals("** DONE [#A] 实现 GTD 视图 :android:feature:", lines(result)[4])
    }

    @Test
    fun setTodoState_emptyHeadlineAcceptsState() {
        val text = "*\n** TODO a"
        val result = OrgEditor.setTodoState(text, 0, "TODO")

        assertEquals("* TODO\n** TODO a", result)
    }

    @Test
    fun setTodoState_clearOnStatelessHeadlineKeepsLine() {
        val text = "** 无状态标题 :tag:"
        val result = OrgEditor.setTodoState(text, 0, null)

        assertEquals("** 无状态标题 :tag:", result)
    }

    @Test
    fun setTodoState_nonHeadlineLineThrows() {
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.setTodoState(source, 0, "TODO") // 第 0 行是 #+TITLE
        }
    }

    @Test
    fun setTodoState_outOfRangeLineThrows() {
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.setTodoState(source, 999, "TODO")
        }
    }
}
