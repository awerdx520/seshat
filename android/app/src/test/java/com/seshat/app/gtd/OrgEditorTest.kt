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

    // ---------- setTitle（M10.6 B4c） ----------

    /** 取文本中第 [index] 个条目（用于行区间改写的测试）。 */
    private fun entryAt(text: String, index: Int): OrgEntry = OrgParser().parse(text).entries[index]

    @Test
    fun setTitle_keepsLevelTodoPriorityAndTags() {
        val text = "* TODO [#A] 旧标题 :android:feature:\n正文\n* 尾巴"
        val entry = entryAt(text, 0)

        val result = OrgEditor.setTitle(text, entry, "新标题")

        assertEquals("* TODO [#A] 新标题 :android:feature:", lines(result)[0])
        assertEquals("正文", lines(result)[1])
        assertEquals("* 尾巴", lines(result)[2])
        val parsed = OrgParser().parse(result).entries[0]
        assertEquals(1, parsed.level)
        assertEquals("TODO", parsed.todoState)
        assertEquals('A', parsed.priority)
        assertEquals(listOf("android", "feature"), parsed.tags)
        assertEquals("新标题", parsed.title)
    }

    @Test
    fun setTitle_onlyTargetLineChanges() {
        val entry = entryAt(source, 1) // 第 4 行：** TODO [#A] 实现 GTD 视图 :android:feature:
        val result = OrgEditor.setTitle(source, entry, "重写标题")

        val before = lines(source)
        val after = lines(result)
        assertEquals(before.size, after.size)
        for (i in before.indices) {
            if (i == 4) continue
            assertEquals("第 $i 行不应改变", before[i], after[i])
        }
    }

    @Test
    fun setTitle_statelessEntryKeepsTags() {
        val text = "** 无状态标题 :reading:\n正文"
        val result = OrgEditor.setTitle(text, entryAt(text, 0), "换过的标题")

        assertEquals("** 换过的标题 :reading:", lines(result)[0])
        assertNull(OrgParser().parse(result).entries[0].todoState)
        assertEquals(listOf("reading"), OrgParser().parse(result).entries[0].tags)
    }

    @Test
    fun setTitle_preservesCrlf() {
        val text = "* TODO 旧标题\r\n正文\r\n* 尾巴"
        val result = OrgEditor.setTitle(text, entryAt(text, 0), "新标题")

        assertEquals("* TODO 新标题\r", lines(result)[0])
        assertEquals("正文\r", lines(result)[1])
        assertEquals("* 尾巴", lines(result)[2])
        assertEquals("新标题", OrgParser().parse(result).entries[0].title)
    }

    // ---------- setBody（M10.6 B4c） ----------

    @Test
    fun setBody_replacesBodyLines() {
        val text = "* A\n旧正文\n* B\nB 正文"
        val entry = entryAt(text, 0)

        val result = OrgEditor.setBody(text, entry, "新正文一\n新正文二")

        assertEquals(listOf("* A", "新正文一", "新正文二", "* B", "B 正文"), lines(result))
        assertEquals("新正文一\n新正文二", OrgParser().parse(result).entries[0].body)
        assertEquals("B 正文", OrgParser().parse(result).entries[1].body)
    }

    @Test
    fun setBody_emptyDeletesBodyLines() {
        val text = "* A\n旧正文一\n旧正文二\n* B\nB 正文"
        val result = OrgEditor.setBody(text, entryAt(text, 0), "")

        assertEquals(listOf("* A", "* B", "B 正文"), lines(result))
        assertEquals("", OrgParser().parse(result).entries[0].body)
    }

    @Test
    fun setBody_preservesCrlf() {
        val text = "* A\r\n旧正文\r\n* B\r\nB 正文"
        val result = OrgEditor.setBody(text, entryAt(text, 0), "新正文")

        // 结构保持 CRLF：除了正文内容，换行风格不变
        assertEquals("* A\r\n新正文\r\n* B\r\nB 正文", result)
    }

    // ---------- insertChild（M10.6 B4c） ----------

    @Test
    fun insertChild_insertsDeeperEntryBeforeEndLine() {
        val text = "* 父\n父正文\n* 兄弟"
        val entry = entryAt(text, 0)

        val result = OrgEditor.insertChild(text, entry, "子标题")

        assertEquals(listOf("* 父", "父正文", "** 子标题", "* 兄弟"), lines(result))
        val parsed = OrgParser().parse(result).entries
        assertEquals(3, parsed.size)
        assertEquals(2, parsed[1].level)
        assertEquals("子标题", parsed[1].title)
        assertEquals("", parsed[1].body)
        assertEquals(2, parsed[1].startLine)
        assertEquals(3, parsed[1].endLine)
        assertEquals("兄弟", parsed[2].title)
    }

    @Test
    fun insertChild_withBodyLines() {
        val text = "* 父\n父正文\n* 兄弟"
        val result = OrgEditor.insertChild(text, entryAt(text, 0), "子标题", "子正文一\n子正文二")

        assertEquals(
            listOf("* 父", "父正文", "** 子标题", "子正文一", "子正文二", "* 兄弟"),
            lines(result),
        )
        assertEquals("子正文一\n子正文二", OrgParser().parse(result).entries[1].body)
    }

    // ---------- 行区间缺失（手工构造的条目） ----------

    @Test
    fun setTitle_missingLineRangeThrows() {
        val manual = OrgEntry(1, "A", null, null, emptyList(), null, null, "")
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.setTitle("* A", manual, "B")
        }
    }

    @Test
    fun setBody_missingLineRangeThrows() {
        val manual = OrgEntry(1, "A", null, null, emptyList(), null, null, "")
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.setBody("* A", manual, "正文")
        }
    }

    @Test
    fun insertChild_missingLineRangeThrows() {
        val manual = OrgEntry(1, "A", null, null, emptyList(), null, null, "")
        assertThrows(IllegalArgumentException::class.java) {
            OrgEditor.insertChild("* A", manual, "子")
        }
    }
}
