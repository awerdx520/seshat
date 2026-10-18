package com.seshat.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [OrgTreeBuilder] 的纯 JVM 单测（不依赖 Android 框架）。 */
class OrgTreeBuilderTest {

    /** 构造一条最小可用的 [OrgEntry]（未用到的字段取默认值）。 */
    private fun entry(
        level: Int,
        title: String,
        body: String = "",
        scheduled: String? = null,
        deadline: String? = null,
    ): OrgEntry = OrgEntry(
        level = level,
        title = title,
        todoState = null,
        priority = null,
        tags = emptyList(),
        scheduled = scheduled,
        deadline = deadline,
        body = body,
    )

    /**
     * 公共测试树（扁平输入 4 条）：
     * ```
     * * A          index 0
     * ** B         index 1
     * *** C        index 2
     * ** D         index 3
     * ```
     */
    private fun sample(): List<OrgEntry> = listOf(
        entry(1, "A"),
        entry(2, "B"),
        entry(3, "C"),
        entry(2, "D"),
    )

    // ---------- build ----------

    @Test
    fun build_singleRoot_returnsOneRootWithoutChildren() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A")))

        assertEquals(1, roots.size)
        assertEquals("A", roots[0].entry.title)
        assertEquals(0, roots[0].index)
        assertTrue(roots[0].children.isEmpty())
    }

    @Test
    fun build_twoLevels_rootHasOneChild() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A"), entry(2, "B")))

        assertEquals(1, roots.size)
        assertEquals(1, roots[0].children.size)
        assertEquals("B", roots[0].children[0].entry.title)
        assertEquals(1, roots[0].children[0].index)
        assertTrue(roots[0].children[0].children.isEmpty())
    }

    @Test
    fun build_threeLevels_nestedToDepthTwo() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A"), entry(2, "B"), entry(3, "C")))

        assertEquals(1, roots.size)
        val c = roots[0].children[0].children
        assertEquals(1, c.size)
        assertEquals("C", c[0].entry.title)
        assertEquals(2, c[0].index)
    }

    @Test
    fun build_siblings_preserveInputOrder() {
        val roots = OrgTreeBuilder.build(
            listOf(entry(1, "A"), entry(2, "B"), entry(2, "C"), entry(2, "D")),
        )

        assertEquals(1, roots.size)
        assertEquals(listOf("B", "C", "D"), roots[0].children.map { it.entry.title })
        assertEquals(listOf(1, 2, 3), roots[0].children.map { it.index })
    }

    @Test
    fun build_levelJump_attachesToNearestLowerAncestor() {
        // `* A` 之后直接 `*** C`（跳过 level 2）：应挂到 A 下（深度 1，而非深度 2）。
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A"), entry(3, "C")))

        assertEquals(1, roots.size)
        assertEquals(1, roots[0].children.size)
        assertEquals(1, roots[0].children[0].index)

        val rows = OrgTreeBuilder.flatten(roots, emptySet())
        assertEquals(listOf(0, 1), rows.map { it.depth })
    }

    @Test
    fun build_firstEntryLevelTwo_becomesRoot() {
        // 首项没有更高级祖先可挂，按规格作为根（depth 0）。
        val roots = OrgTreeBuilder.build(listOf(entry(2, "A"), entry(3, "B")))

        assertEquals(1, roots.size)
        assertEquals(0, roots[0].index)
        assertEquals(listOf(1), roots[0].children.map { it.index })

        val rows = OrgTreeBuilder.flatten(roots, emptySet())
        assertEquals(listOf(0, 1), rows.map { it.depth })
    }

    @Test
    fun build_backToUpperLevel_startsNewRoot() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A"), entry(2, "B"), entry(1, "C")))

        assertEquals(2, roots.size)
        assertEquals(listOf(0, 2), roots.map { it.index })
        assertEquals(listOf("A", "C"), roots.map { it.entry.title })
        assertEquals(listOf(1), roots[0].children.map { it.index })
        assertTrue(roots[1].children.isEmpty())
    }

    // ---------- flatten ----------

    @Test
    fun flatten_withoutCollapsed_emitsAllRowsInPreOrder() {
        val rows = OrgTreeBuilder.flatten(OrgTreeBuilder.build(sample()), emptySet())

        assertEquals(listOf(0, 1, 2, 3), rows.map { it.node.index })
        assertEquals(listOf(0, 1, 2, 1), rows.map { it.depth })
        assertEquals(listOf(true, true, false, false), rows.map { it.hasChildren })
        assertEquals(listOf(false, false, false, false), rows.map { it.collapsed })
    }

    @Test
    fun flatten_collapsedNode_hidesSubtreeAndMarksRowCollapsed() {
        val rows = OrgTreeBuilder.flatten(OrgTreeBuilder.build(sample()), setOf(1))

        // B(index 1) 折叠 → 其子 C(index 2) 不出现。
        assertEquals(listOf(0, 1, 3), rows.map { it.node.index })
        assertEquals(listOf(false, true, false), rows.map { it.collapsed })
        assertEquals(listOf(0, 1, 1), rows.map { it.depth })
    }

    @Test
    fun flatten_collapsedRoot_leavesOnlyRootRow() {
        val rows = OrgTreeBuilder.flatten(OrgTreeBuilder.build(sample()), setOf(0))

        assertEquals(1, rows.size)
        assertEquals(0, rows[0].node.index)
        assertEquals(0, rows[0].depth)
        assertTrue(rows[0].hasChildren)
        assertTrue(rows[0].collapsed)
    }

    // ---------- flattenFiltered ----------

    @Test
    fun flattenFiltered_leafMatch_keepsAncestorChain() {
        val roots = OrgTreeBuilder.build(sample())

        val rows = OrgTreeBuilder.flattenFiltered(roots, setOf(2), emptySet())

        // 命中的是叶 C(2)，祖先链 A(0) → B(1) 必须保留，同级的 D(3) 隐藏。
        assertEquals(listOf(0, 1, 2), rows.map { it.node.index })
        assertEquals(listOf(0, 1, 2), rows.map { it.depth })
    }

    @Test
    fun flattenFiltered_rootAndLeafMatch_hidesSiblingBranch() {
        val roots = OrgTreeBuilder.build(sample())

        // 命中根 A(0) 与叶 C(2)：D(3) 既不命中也不是命中节点的祖先 → 整支隐藏。
        val rows = OrgTreeBuilder.flattenFiltered(roots, setOf(0, 2), emptySet())

        assertEquals(listOf(0, 1, 2), rows.map { it.node.index })
        assertTrue(rows.none { it.node.index == 3 })
        assertEquals(listOf(0, 1, 2), rows.map { it.depth })
    }

    @Test
    fun flattenFiltered_ignoresCollapsed_forcedExpand() {
        val roots = OrgTreeBuilder.build(sample())

        // 命中叶 C(2) 且 B(1) 处于折叠状态：命中分支强制展开，B 不标记为 collapsed。
        val rows = OrgTreeBuilder.flattenFiltered(roots, setOf(2), setOf(1))

        assertEquals(listOf(0, 1, 2), rows.map { it.node.index })
        assertEquals(listOf(false, false, false), rows.map { it.collapsed })
    }

    @Test
    fun flattenFiltered_noMatch_returnsEmptyRows() {
        val roots = OrgTreeBuilder.build(sample())

        assertTrue(OrgTreeBuilder.flattenFiltered(roots, emptySet(), emptySet()).isEmpty())
    }

    @Test
    fun flattenFiltered_hasChildrenReflectsVisibleChildrenOnly() {
        val roots = OrgTreeBuilder.build(sample())

        // 命中根 A(0) 与叶 C(2)：D(3) 隐藏后，B(1) 的可见子节点只剩 C。
        val rows = OrgTreeBuilder.flattenFiltered(roots, setOf(0, 2), emptySet())

        assertTrue(rows[0].hasChildren) // A 仍有可见子 B
        assertTrue(rows[1].hasChildren) // B 仍有可见子 C
        assertFalse(rows[2].hasChildren) // C 无可见子
    }
}
