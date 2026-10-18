package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [ScrollProgressMath] 的纯 JVM 单测（无 Android 依赖）。
 *
 * 覆盖三类语义：
 * 1. 首个可见项顶部已滚出视口（`itemTop <= 0`）→ 直接取该位置 + 滚出像素；
 * 2. 首个可见项顶部在视口下方（`itemTop > 0`）→ 回退到上一项，偏移为「上一项高度 − itemTop」；
 * 3. 异常输入（首个位置为 0 或负数、上一项高度未知）→ 偏移不产生负值。
 */
class ScrollProgressMathTest {

    @Test
    fun zeroItemTopKeepsPositionWithZeroOffset() {
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 3,
            itemTop = 0,
            previousItemHeight = 1600,
        )
        assertEquals(ScrollAnchor(3, 0), anchor)
    }

    @Test
    fun negativeItemTopBecomesPositiveOffset() {
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 3,
            itemTop = -120,
            previousItemHeight = 1600,
        )
        assertEquals(ScrollAnchor(3, 120), anchor)
    }

    @Test
    fun positiveItemTopRollsBackToPreviousItem() {
        // position=3、itemTop=80、prevHeight=1600 → 实际阅读位置是第 2 项内部「上一项已滚出 1520px」处。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 3,
            itemTop = 80,
            previousItemHeight = 1600,
        )
        assertEquals(ScrollAnchor(2, 1520), anchor)
    }

    @Test
    fun firstItemWithPositiveTopClampsToZeroOffset() {
        // 第 0 项顶部在视口下方（尚未滚动的顶部空白）→ 无上一项可退，规范化为 (0, 0)。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 0,
            itemTop = 80,
            previousItemHeight = 1600,
        )
        assertEquals(ScrollAnchor(0, 0), anchor)
    }

    @Test
    fun roundTripRestoresNegativeScrollOffset() {
        // 往返一致性：视口信息 → 锚点 → scrollToPositionWithOffset 的 offset。
        // 注意：期望值是 -40（项顶在视口上方 40px），与 `itemOffsetFor` 的「负值表示已滚出」语义一致。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 5,
            itemTop = -40,
            previousItemHeight = 1200,
        )
        assertEquals(ScrollAnchor(5, 40), anchor)
        assertEquals(-40, ScrollProgressMath.itemOffsetFor(anchor))
    }

    @Test
    fun roundTripOfAlignedItemYieldsZeroOffset() {
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 7,
            itemTop = 0,
            previousItemHeight = 1200,
        )
        assertEquals(ScrollAnchor(7, 0), anchor)
        assertEquals(0, ScrollProgressMath.itemOffsetFor(anchor))
    }

    @Test
    fun oversizedPositiveTopAtFirstItemNeverYieldsNegativeOffset() {
        // 异常值（首项应恒为 itemTop <= 0）→ 归一为 (0, 0)，offset 不为负。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 0,
            itemTop = 500,
            previousItemHeight = 1000,
        )
        assertEquals(ScrollAnchor(0, 0), anchor)
        assertTrue(anchor.offset >= 0)
        assertTrue(ScrollProgressMath.itemOffsetFor(anchor) <= 0)
    }

    @Test
    fun unknownPreviousHeightStillProducesNonNegativeOffset() {
        // 上一项高度未知（0）时退到上一项：无法换算偏移，退化为上一项顶端（offset = 0）。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = 3,
            itemTop = 80,
            previousItemHeight = 0,
        )
        assertEquals(ScrollAnchor(2, 0), anchor)
        assertTrue(anchor.offset >= 0)
    }

    @Test
    fun negativeVisiblePositionTreatedAsFirstItem() {
        // findFirstVisibleItemPosition() 可能返回 -1（无可见项）→ 归一为第 0 项。
        val anchor = ScrollProgressMath.progressFromViewport(
            visiblePosition = -1,
            itemTop = -30,
            previousItemHeight = 800,
        )
        assertEquals(ScrollAnchor(0, 30), anchor)
    }

    @Test
    fun itemOffsetForClampsPositiveOffsetToZero() {
        // 防御性：即便传入非规范锚点（offset 为负），返回的滚动 offset 也不为正。
        assertEquals(0, ScrollProgressMath.itemOffsetFor(ScrollAnchor(2, -10)))
        assertEquals(-1990, ScrollProgressMath.itemOffsetFor(ScrollAnchor(2, 1990)))
    }

    // ---- 视口中心项：多项同屏时「当前项」应取覆盖视口中心的那一项 ----

    /** 两项同屏的基准布局：第 0 项 [0,100)、第 1 项 [100,300)。 */
    private fun twoItems(): List<ItemBounds> =
        listOf(ItemBounds(0, 0, 100), ItemBounds(1, 100, 300))

    @Test
    fun centerInFirstItemReturnsFirst() {
        // 中心点 50 落在第 0 项 [0,100) 内 → 第 0 项。
        assertEquals(0, ScrollProgressMath.visibleCenterPosition(twoItems(), 50) ?: -1)
    }

    @Test
    fun centerInSecondItemReturnsSecond() {
        // 中心点 200 落在第 1 项 [100,300) 内 → 第 1 项。
        assertEquals(1, ScrollProgressMath.visibleCenterPosition(twoItems(), 200) ?: -1)
    }

    @Test
    fun boundaryBelongsToNextItem() {
        // 半开区间 [top, bottom)：中心点恰好落在两项交界（第 0 项 bottom == 第 1 项 top == 100）
        // 时归入下一项，符合「继续向下滚动」的直觉。
        assertEquals(1, ScrollProgressMath.visibleCenterPosition(twoItems(), 100) ?: -1)
    }

    @Test
    fun emptyItemsReturnsNull() {
        assertNull(ScrollProgressMath.visibleCenterPosition(emptyList(), 50))
    }

    @Test
    fun centerAboveAllItemsReturnsFirst() {
        // 中心点在所有项上方（10 < 首项 top 100）→ 距离最近的仍是第 0 项。
        val items = listOf(ItemBounds(0, 100, 200), ItemBounds(1, 200, 400))
        assertEquals(0, ScrollProgressMath.visibleCenterPosition(items, 10) ?: -1)
    }

    @Test
    fun centerBelowAllItemsReturnsLast() {
        // 中心点在所有项下方（900 > 末项 bottom 400）→ 距离最近的末项。
        val items = listOf(ItemBounds(0, 100, 200), ItemBounds(1, 200, 400))
        assertEquals(1, ScrollProgressMath.visibleCenterPosition(items, 900) ?: -1)
    }
}
