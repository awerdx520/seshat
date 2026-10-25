package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * [TocDrawerText] 的纯 JVM 单测（无 Android 依赖、无 Robolectric）。
 *
 * 守的不变量：
 * - 书签空态第一行恒为「尚无书签」（否则空区域毫无解释）；
 * - 只有**支持书签**的阅读器才给出「点顶栏的书签图标可添加」的操作指引——EPUB 没有书签入口，
 *   渲染这条提示会指向一个不存在的按钮（E9）；
 * - 状态行两段拼接的分隔符固定，改格式时测试会先失败。
 */
class TocDrawerTextTest {

    @Test
    fun emptyBookmarkLinesKeepsHintWhenBookmarksSupported() {
        val lines = TocDrawerText.emptyBookmarkLines(bookmarksSupported = true)

        assertEquals("尚无书签", lines.first)
        assertNotNull("支持书签时必须有操作指引", lines.second)
        assertEquals("阅读时点顶栏的书签图标可添加", lines.second)
    }

    @Test
    fun emptyBookmarkLinesDropsHintWhenBookmarksUnsupported() {
        val lines = TocDrawerText.emptyBookmarkLines(bookmarksSupported = false)

        assertEquals("尚无书签", lines.first)
        assertNull("EPUB 没有书签入口，不能渲染指向该书签图标的指引", lines.second)
    }

    @Test
    fun statusSeparatorIsStable() {
        // 状态行 =「第 x/y 页」+ 分隔符 +「n 个书签」，分隔符变化会让 UI 文案漂移
        assertEquals(" · ", TocDrawerText.STATUS_SEPARATOR)
    }
}
