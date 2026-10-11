package com.notes.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [GtdFilter] 组合过滤 + [OrgDocument] 过滤方法的纯 JVM 单测（不依赖 Android 框架）。
 *
 * 用内存构造的 [OrgDocument] / [OrgEntry]，覆盖 byTag / byPriority / byTodoState / todoEntries
 * 以及三者组合（状态 + 优先级 + 标签）的语义。
 */
class GtdFilterTest {

    /** 构造一个最小 [OrgEntry]（仅填过滤相关字段）。 */
    private fun entry(
        title: String,
        state: String? = null,
        priority: Char? = null,
        tags: List<String> = emptyList(),
    ) = OrgEntry(
        level = 1,
        title = title,
        todoState = state,
        priority = priority,
        tags = tags,
        scheduled = null,
        deadline = null,
        body = "",
    )

    /** 内存构造的文档：覆盖 有/无 TODO 状态、不同优先级、不同标签 的组合。 */
    private val doc = OrgDocument(
        listOf(
            entry("A", state = "TODO", priority = 'A', tags = listOf("x", "work")),
            entry("B", state = "TODO", priority = 'B', tags = listOf("y")),
            entry("C", state = "DONE", priority = 'A', tags = listOf("x")),
            entry("D", state = null, priority = null, tags = listOf("home")),
            entry("E", state = "NEXT", priority = 'C', tags = listOf("work")),
        ),
    )

    private fun titles(entries: List<OrgEntry>): List<String> = entries.map { it.title }

    // ---------- 单维度 ----------

    @Test
    fun filter_noCriteria_returnsAllPreservingOrder() {
        val result = GtdFilter.filter(doc.entries)

        assertEquals(listOf("A", "B", "C", "D", "E"), titles(result))
    }

    @Test
    fun filter_byTodoState_exactMatchOnly() {
        assertEquals(listOf("A", "B"), titles(GtdFilter.filter(doc.entries, todoState = "TODO")))
        assertEquals(listOf("C"), titles(GtdFilter.filter(doc.entries, todoState = "DONE")))
        assertEquals(listOf("E"), titles(GtdFilter.filter(doc.entries, todoState = "NEXT")))
        // 无状态条目不会被任何具体状态命中
        assertTrue(GtdFilter.filter(doc.entries, todoState = "WAITING").isEmpty())
    }

    @Test
    fun filter_byPriority_ignoresCase() {
        assertEquals(listOf("A", "C"), titles(GtdFilter.filter(doc.entries, priority = 'A')))
        assertEquals(listOf("A", "C"), titles(GtdFilter.filter(doc.entries, priority = 'a')))
        assertEquals(listOf("B"), titles(GtdFilter.filter(doc.entries, priority = 'B')))
        assertEquals(listOf("E"), titles(GtdFilter.filter(doc.entries, priority = 'C')))
    }

    @Test
    fun filter_byTag_membershipMatch() {
        assertEquals(listOf("A", "C"), titles(GtdFilter.filter(doc.entries, tag = "x")))
        assertEquals(listOf("A", "E"), titles(GtdFilter.filter(doc.entries, tag = "work")))
        assertEquals(listOf("D"), titles(GtdFilter.filter(doc.entries, tag = "home")))
        assertTrue(GtdFilter.filter(doc.entries, tag = "missing").isEmpty())
    }

    // ---------- 组合维度 ----------

    @Test
    fun filter_combined_stateAndPriority() {
        val result = GtdFilter.filter(doc.entries, todoState = "TODO", priority = 'A')

        assertEquals(listOf("A"), titles(result))
    }

    @Test
    fun filter_combined_stateAndTag() {
        val result = GtdFilter.filter(doc.entries, todoState = "TODO", tag = "work")

        assertEquals(listOf("A"), titles(result))
    }

    @Test
    fun filter_combined_priorityAndTag() {
        val result = GtdFilter.filter(doc.entries, priority = 'A', tag = "x")

        assertEquals(listOf("A", "C"), titles(result))
    }

    @Test
    fun filter_combined_allThreeDimensions() {
        val result = GtdFilter.filter(doc.entries, todoState = "TODO", priority = 'A', tag = "work")

        assertEquals(listOf("A"), titles(result))
    }

    @Test
    fun filter_combined_allThree_noMatch_returnsEmpty() {
        // 状态 DONE 与优先级 B 不存在交集
        val result = GtdFilter.filter(doc.entries, todoState = "DONE", priority = 'B')

        assertTrue(result.isEmpty())
    }

    @Test
    fun filter_combined_nullDimensionsAreIgnored() {
        val result = GtdFilter.filter(doc.entries, todoState = "TODO", priority = null, tag = null)

        assertEquals(listOf("A", "B"), titles(result))
    }

    // ---------- OrgDocument 既有过滤方法（组合复用验证） ----------

    @Test
    fun document_methods_composeWithGtdFilter() {
        // todoEntries() 先筛出带状态条目，再用 GtdFilter 叠加优先级/标签
        val todos = doc.todoEntries()
        assertEquals(listOf("A", "B", "C", "E"), titles(todos))

        val highPriority = GtdFilter.filter(todos, priority = 'A')
        assertEquals(listOf("A", "C"), titles(highPriority))

        val workTag = GtdFilter.filter(todos, tag = "work")
        assertEquals(listOf("A", "E"), titles(workTag))
    }

    @Test
    fun document_methods_matchGtdFilterSemantics() {
        // byTodoState / byPriority / byTag 与 GtdFilter 单维度结果一致
        assertEquals(
            titles(doc.byTodoState("TODO")),
            titles(GtdFilter.filter(doc.entries, todoState = "TODO")),
        )
        assertEquals(
            titles(doc.byPriority('A')),
            titles(GtdFilter.filter(doc.entries, priority = 'A')),
        )
        assertEquals(
            titles(doc.byTag("x")),
            titles(GtdFilter.filter(doc.entries, tag = "x")),
        )
    }
}
