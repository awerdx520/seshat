package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Test

/**
 * [ReaderChrome] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：阅读区 padding 只由「浮层可见性 + 已测量高度」两个输入决定——
 * 隐藏必须归零（缺陷 U1 的回归锚点：浮层隐藏后底部不能再留一条等高的空白）、
 * 高度未测量（`<= 0`）一律按 0 计、高度变化必须重算（不能被缓存吞掉）。
 */
class ReaderChromeTest {

    @Test
    fun bothVisibleKeepsBothHeights() {
        // 两块浮层都可见：上下各自留出自身高度，正文既不被遮挡也能延伸浮层下方。
        assertEquals(
            ReaderChrome.ContentPadding(120, 80),
            ReaderChrome.padding(topVisible = true, bottomVisible = true, topHeight = 120, bottomHeight = 80),
        )
    }

    @Test
    fun topHiddenBottomVisible() {
        // 顶部隐藏、底部可见：只留底部高度（两者独立判断，不能「任一隐藏就全清零」）
        assertEquals(
            ReaderChrome.ContentPadding(0, 80),
            ReaderChrome.padding(topVisible = false, bottomVisible = true, topHeight = 120, bottomHeight = 80),
        )
    }

    @Test
    fun bottomHiddenTopVisible() {
        // 底部隐藏、顶部可见：只留顶部高度（与上一个用例对称）
        assertEquals(
            ReaderChrome.ContentPadding(120, 0),
            ReaderChrome.padding(topVisible = true, bottomVisible = false, topHeight = 120, bottomHeight = 80),
        )
    }

    @Test
    fun bothHiddenIsZero() {
        // U1 的回归锚点：浮层隐藏（GONE）后 `height` 仍返回上一次测量的旧值，
        // 必须由可见性决定归零，否则阅读区上下各留一条浮层等高的空白。
        assertEquals(
            ReaderChrome.ContentPadding(0, 0),
            ReaderChrome.padding(topVisible = false, bottomVisible = false, topHeight = 120, bottomHeight = 80),
        )
    }

    @Test
    fun unmeasuredHeightTreatedAsZero() {
        // 可见但尚未测量（height == 0）：按 0 计——此时 Activity 侧会提前 return 等下一次布局，
        // 纯函数只需保证不把 0 之外的脏值往上带。
        assertEquals(
            ReaderChrome.ContentPadding(0, 0),
            ReaderChrome.padding(topVisible = true, bottomVisible = true, topHeight = 0, bottomHeight = 0),
        )
    }

    @Test
    fun negativeHeightTreatedAsZero() {
        // 高度为负（理论上的异常测量结果）同样按 0 计，绝不能让 padding 变负。
        assertEquals(
            ReaderChrome.ContentPadding(0, 0),
            ReaderChrome.padding(topVisible = true, bottomVisible = true, topHeight = -5, bottomHeight = -5),
        )
    }

    @Test
    fun heightChangedRecomputes() {
        // 高度变化必须重算：字体缩放/旋转屏/insets 都会改浮层高度，缓存旧值会遮住末几行。
        val before = ReaderChrome.padding(true, true, 120, 80)
        val after = ReaderChrome.padding(true, true, 150, 100)
        assertNotEquals("高度变化后 padding 必须跟着变", before, after)
        assertEquals(ReaderChrome.ContentPadding(150, 100), after)
    }

    @Test
    fun asymmetricHeightsNotSwapped() {
        // 上下高度不同时不得串位：顶部只吃 topHeight、底部只吃 bottomHeight
        // （守护 Activity 侧调用 `ReaderChrome.padding(topVisible, bottomVisible, topHeight, bottomHeight)`
        //  的实参顺序——四参同型，写反了编译器不会报错）。
        assertEquals(
            ReaderChrome.ContentPadding(80, 120),
            ReaderChrome.padding(topVisible = true, bottomVisible = true, topHeight = 80, bottomHeight = 120),
        )
    }

    @Test
    fun topUnmeasuredKeepsBottomPadding() {
        // 顶部可见但尚未测量（height == 0）、底部已测量：顶部按 0 计，底部照常预留——
        // 两块浮层各自独立判定，一块未测量不能把另一块的有效 padding 一并清零。
        assertEquals(
            ReaderChrome.ContentPadding(0, 80),
            ReaderChrome.padding(topVisible = true, bottomVisible = true, topHeight = 0, bottomHeight = 80),
        )
    }
}
