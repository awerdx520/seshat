package com.notes.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** [OrgParser] 的纯 JVM 单测（不依赖 Android 框架）。 */
class OrgParserTest {

    private val parser = OrgParser()

    // ---------- 标题层级 ----------

    @Test
    fun parse_multiLevelHeadings_assignsLevelByStarCount() {
        val doc = parser.parse("* A\n** B\n*** C")

        assertEquals(3, doc.entries.size)
        assertEquals(listOf(1, 2, 3), doc.entries.map { it.level })
        assertEquals(listOf("A", "B", "C"), doc.entries.map { it.title })
        assertEquals(listOf("", "", ""), doc.entries.map { it.body })
    }

    @Test
    fun parse_starWithTitleIsHeadline_butBoldTextIsNot() {
        // 星号后紧跟非空白（如 **bold**）不应判为标题。
        val doc = parser.parse("* A\n**bold** text")

        assertEquals(1, doc.entries.size)
        assertEquals("A", doc.entries[0].title)
        assertEquals("**bold** text", doc.entries[0].body)
    }

    // ---------- TODO 状态 ----------

    @Test
    fun parse_recognizesDefaultTodoStates() {
        val doc = parser.parse("* TODO 一\n* DONE 二\n* NEXT 三")

        assertEquals(listOf("TODO", "DONE", "NEXT"), doc.entries.map { it.todoState })
        assertEquals(listOf("一", "二", "三"), doc.entries.map { it.title })
    }

    @Test
    fun parse_allDefaultKeywords_recognized() {
        val keywords = listOf("TODO", "NEXT", "STARTED", "WAITING", "HOLD", "DONE", "CANCELLED")
        val doc = parser.parse(keywords.joinToString("\n") { "* $it Task" })

        assertEquals(keywords, doc.entries.map { it.todoState })
        assertTrue(doc.entries.all { it.title == "Task" })
    }

    @Test
    fun parse_keywordOnlyHeadline_yieldsEmptyTitle() {
        val doc = parser.parse("* TODO")

        assertEquals(1, doc.entries.size)
        assertEquals("TODO", doc.entries[0].todoState)
        assertEquals("", doc.entries[0].title)
    }

    @Test
    fun parse_customTodoKeywords_excludesUnknown() {
        val custom = OrgParser(setOf("TODO", "DONE"))
        val doc = custom.parse("* NEXT Task")

        assertNull(doc.entries[0].todoState)
        assertEquals("NEXT Task", doc.entries[0].title)
    }

    // ---------- 优先级 ----------

    @Test
    fun parse_priorityInHeadline_uppercasedChar() {
        val doc = parser.parse("* TODO [#A] 修 bug")

        assertEquals("TODO", doc.entries[0].todoState)
        assertEquals('A', doc.entries[0].priority)
        assertEquals("修 bug", doc.entries[0].title)
    }

    @Test
    fun parse_lowercasePriority_uppercased() {
        val doc = parser.parse("* [#b] 小写优先级")

        assertEquals('B', doc.entries[0].priority)
        assertEquals("小写优先级", doc.entries[0].title)
    }

    @Test
    fun parse_priorityFromPropertiesBlock_whenAbsentInHeadline() {
        val doc = parser.parse(
            """
            * 任务
              :PROPERTIES:
              :PRIORITY: A
              :END:
            """.trimIndent(),
        )

        assertEquals(1, doc.entries.size)
        assertEquals('A', doc.entries[0].priority)
        assertEquals("任务", doc.entries[0].title)
    }

    @Test
    fun parse_headlinePriority_hasPrecedenceOverProperties() {
        val doc = parser.parse(
            """
            * [#C] 任务
              :PROPERTIES:
              :PRIORITY: A
              :END:
            """.trimIndent(),
        )

        assertEquals('C', doc.entries[0].priority)
    }

    // ---------- 标签 ----------

    @Test
    fun parse_stripsTrailingTags() {
        val doc = parser.parse("* TODO 发布 :work:urgent:")

        assertEquals(listOf("work", "urgent"), doc.entries[0].tags)
        assertEquals("发布", doc.entries[0].title)
        assertEquals("TODO", doc.entries[0].todoState)
    }

    @Test
    fun parse_tagWithAtSign() {
        val doc = parser.parse("* 给妈妈打电话 :@phone:")

        assertEquals(listOf("@phone"), doc.entries[0].tags)
        assertEquals("给妈妈打电话", doc.entries[0].title)
    }

    @Test
    fun parse_noTags_returnsEmptyList() {
        val doc = parser.parse("* 普通标题")

        assertTrue(doc.entries[0].tags.isEmpty())
    }

    // ---------- 计划时间 ----------

    @Test
    fun parse_scheduledAndDeadline_takeRawInnerString() {
        val doc = parser.parse(
            """
            * 会议
              SCHEDULED: <2026-10-11>
              DEADLINE: <2026-10-15>
            """.trimIndent(),
        )

        assertEquals("2026-10-11", doc.entries[0].scheduled)
        assertEquals("2026-10-15", doc.entries[0].deadline)
    }

    @Test
    fun parse_scheduledWithTime_keepsRawString() {
        val doc = parser.parse("* 提醒\n  SCHEDULED: <2026-10-11 Sat 09:30>")

        assertEquals("2026-10-11 Sat 09:30", doc.entries[0].scheduled)
        assertNull(doc.entries[0].deadline)
    }

    // ---------- 组合剥离 ----------

    @Test
    fun parse_fullHeadline_stripsTodoPriorityAndTags() {
        val doc = parser.parse("* TODO [#A] 修复登录 bug :urgent:backend:")

        val entry = doc.entries[0]
        assertEquals("TODO", entry.todoState)
        assertEquals('A', entry.priority)
        assertEquals(listOf("urgent", "backend"), entry.tags)
        assertEquals("修复登录 bug", entry.title)
    }

    // ---------- body 归属 ----------

    @Test
    fun parse_bodyBelongsToPrecedingHeading() {
        val doc = parser.parse(
            """
            * A
            line one
            line two
            ** B
            line three
            """.trimIndent(),
        )

        assertEquals(2, doc.entries.size)
        assertEquals("line one\nline two", doc.entries[0].body)
        assertEquals("line three", doc.entries[1].body)
    }

    @Test
    fun parse_textBeforeFirstHeadline_isIgnored() {
        val doc = parser.parse("前言散落文本\n* A")

        assertEquals(1, doc.entries.size)
        assertEquals("A", doc.entries[0].title)
        assertEquals("", doc.entries[0].body)
    }

    // ---------- 空文本 ----------

    @Test
    fun parse_emptyText_yieldsNoEntries() {
        assertTrue(parser.parse("").entries.isEmpty())
        assertTrue(parser.parse("   \n\n").entries.isEmpty())
    }

    // ---------- 过滤方法 ----------

    @Test
    fun parse_noTodoEntries_yieldsEmptyTodoEntries() {
        val doc = parser.parse("* 一\n* 二")

        assertEquals(2, doc.entries.size)
        assertTrue(doc.todoEntries().isEmpty())
    }

    @Test
    fun document_filters_workAsExpected() {
        val doc = parser.parse(
            """
            * TODO [#A] 任务 A :x:
            * TODO [#B] 任务 B :y:
            * DONE [#A] 任务 C :x:
            """.trimIndent(),
        )

        assertEquals(3, doc.todoEntries().size)
        assertEquals(listOf("TODO", "TODO", "DONE"), doc.entries.map { it.todoState })

        assertEquals(2, doc.byTag("x").size)
        assertEquals(listOf("任务 A", "任务 C"), doc.byTag("x").map { it.title })
        assertTrue(doc.byTag("missing").isEmpty())

        assertEquals(2, doc.byPriority('A').size)
        assertEquals(2, doc.byPriority('a').size) // 忽略大小写
        assertEquals(1, doc.byPriority('B').size)

        assertEquals(2, doc.byTodoState("TODO").size)
        assertEquals(1, doc.byTodoState("DONE").size)
        assertTrue(doc.byTodoState("NEXT").isEmpty())
    }

    @Test
    fun document_todoEntriesExposeState() {
        val doc = parser.parse("* TODO 事情\n* 无状态")
        val todos = doc.todoEntries()

        assertEquals(1, todos.size)
        assertNotNull(todos[0].todoState)
        assertEquals("事情", todos[0].title)
    }
}
