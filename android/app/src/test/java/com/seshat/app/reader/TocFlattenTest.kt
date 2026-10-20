package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [TocFlatten] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：折叠时只留根行、展开一层只露一层、depth 上限随每个可见行重算、
 * 未知 id 不影响结果、输出保持输入顺序、`expanded` 标记按集合回填（叶子恒 false）、
 * 以及兄弟容器各按自己的 id 独立展开（id 唯一性的端到端验证）。
 */
class TocFlattenTest {

    /**
     * 三层目录的完整 DFS 前序行表（与 [TocRows] 产出一致，未折叠）：
     *
     * ```
     * 0            depth 0, 容器
     * ├─ 0/0       depth 1, 容器
     * │  ├─ 0/0/0  depth 2, 叶子
     * │  └─ 0/0/1  depth 2, 叶子
     * └─ 0/1       depth 1, 叶子
     * 1            depth 0, 容器（0 的兄弟容器）
     * └─ 1/0       depth 1, 叶子
     * 2            depth 0, 叶子
     * ```
     */
    private val rows = listOf(
        row("0", depth = 0, hasChildren = true),
        row("0/0", depth = 1, hasChildren = true),
        row("0/0/0", depth = 2),
        row("0/0/1", depth = 2),
        row("0/1", depth = 1),
        row("1", depth = 0, hasChildren = true),
        row("1/0", depth = 1),
        row("2", depth = 0),
    )

    /** 只关心 id / depth / hasChildren 的行构造器；title 用 id 便于断言，expanded 留字段默认 false。 */
    private fun row(id: String, depth: Int, hasChildren: Boolean = false) = TocRow(
        title = id,
        targetIndex = 0,
        depth = depth,
        hasChildren = hasChildren,
        id = id,
    )

    private fun ids(list: List<TocRow>): List<String> = list.map { it.id }

    @Test
    fun collapsedShowsOnlyRoots() {
        // 空展开集合：所有子树被折叠，只剩 depth 0 的行，且顺序不变。
        val visible = TocFlatten.visibleRows(rows, emptySet())

        assertEquals(listOf("0", "1", "2"), ids(visible))
        assertTrue(visible.all { it.depth == 0 })
    }

    @Test
    fun expandedFirstLevelShowsItsChildren() {
        // 只展开 "0"：depth 1 的子节点出现，depth 2 的孙节点仍被（折叠的 0/0）挡住。
        val visible = TocFlatten.visibleRows(rows, setOf("0"))

        assertEquals(listOf("0", "0/0", "0/1", "1", "2"), ids(visible))
        assertTrue(visible.none { it.depth == 2 })
    }

    @Test
    fun expandedTwoLevelsShowsGrandchildren() {
        // "0" 与 "0/0" 都展开：depth 2 的孙节点出现。
        val visible = TocFlatten.visibleRows(rows, setOf("0", "0/0"))

        assertEquals(listOf("0", "0/0", "0/0/0", "0/0/1", "0/1", "1", "2"), ids(visible))
        assertEquals(2, visible.count { it.depth == 2 })
    }

    @Test
    fun unknownIdIsIgnored() {
        // 集合里混入不存在的 id（或叶子 id、其他容器的子节点 id）：结果与空集合完全一致。
        assertEquals(
            ids(TocFlatten.visibleRows(rows, emptySet())),
            ids(TocFlatten.visibleRows(rows, setOf("9/9"))),
        )
        // 叶子 "2" 与未展开容器的子节点 "1/0" 也在集合里，但都不会让任何子行冒出来。
        assertEquals(
            ids(TocFlatten.visibleRows(rows, emptySet())),
            ids(TocFlatten.visibleRows(rows, setOf("2", "1/0"))),
        )
    }

    @Test
    fun emptyRowsReturnsEmpty() {
        assertTrue(TocFlatten.visibleRows(emptyList(), setOf("0", "0/0")).isEmpty())
        assertTrue(TocFlatten.visibleRows(emptyList(), emptySet()).isEmpty())
    }

    @Test
    fun siblingContainersToggleIndependently() {
        // 两个容器兄弟（"0" 与 "1"）各自有子节点：展开 "0" 只露 "0" 的子节点，"1/0" 必须不出现。
        val visible = TocFlatten.visibleRows(rows, setOf("0"))
        val visibleIds = ids(visible)

        assertTrue(visibleIds.containsAll(listOf("0/0", "0/1")))
        assertFalse(visibleIds.contains("1/0"))
        // 反向：展开 "1" 时只露 "1/0"，"0" 的子节点全部隐藏。
        val other = ids(TocFlatten.visibleRows(rows, setOf("1")))
        assertTrue(other.contains("1/0"))
        assertFalse(other.contains("0/0"))
        assertEquals(listOf("0", "1", "1/0", "2"), other)
    }

    @Test
    fun expandedFlagIsFilledForVisibleRows() {
        // 可见行按集合回填 expanded：展开的容器 true、折叠的容器 false、叶子恒 false。
        val visible = TocFlatten.visibleRows(rows, setOf("0", "0/1", "2"))
        val byId = visible.associateBy { it.id }

        assertEquals(true, byId.getValue("0").expanded) // 有子节点且已展开
        assertEquals(false, byId.getValue("0/0").expanded) // 有子节点但未展开
        assertEquals(false, byId.getValue("1").expanded) // 有子节点但未展开
        assertEquals(false, byId.getValue("2").expanded) // 叶子，即使 id 在集合里也恒 false
        // "0/1" 是叶子且 id 在集合里，只有 depth 1 可见时才出现；此集合下它可见。
        assertEquals(false, byId.getValue("0/1").expanded)
    }

    @Test
    fun orderIsPreserved() {
        // 输出必须是输入的按序子集：顺序与输入完全一致，不重排、不重复。
        val visible = TocFlatten.visibleRows(rows, setOf("1"))
        val visibleIds = ids(visible)

        assertEquals(listOf("0", "1", "1/0", "2"), visibleIds)
        assertEquals(visibleIds, ids(rows).filter { it in visibleIds })
    }
}
