package com.seshat.app.reader

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [LocationScroll] 的脚本生成单测（M10.3 T5，EPUB 章内定位）。
 *
 * 只测**纯函数** [LocationScroll.script]（不构造 WebView、不跑 JS）：
 * - 模板占位符必须被替换干净——脚本里残留 `__TARGET__` 会直接是语法错误，
 *   残留 `TOP_MARGIN` 会让 `rect.top - TOP_MARGIN` 变成 `NaN`，两种都是**静默失败**
 *   （定位不生效、无异常、无日志），故必须由测试兜住；
 * - 目标偏移以**数字字面量**注入（不做字符串拼接，避免注入）；
 * - 负数与超大值按 `[0, MAX_OFFSET]` 夹紧（异常数据不得把脚本撑大）。
 *
 * 本仓库无 androidTest 目录，真机上的滚动效果只能手工验收；这里覆盖的是「脚本本身合法」这一层。
 */
class LocationScrollTest {

    @Test
    fun `script 替换全部占位符且不留模板标记`() {
        val script = LocationScroll.script(42)
        assertFalse("残留 __TARGET__ 占位符", script.contains("__TARGET__"))
        assertFalse("残留 TOP_MARGIN 占位符（会算出 NaN）", script.contains("TOP_MARGIN"))
        assertTrue("目标是数字字面量", script.contains("})(42)"))
    }

    @Test
    fun `script 保留滚动与文本流遍历的关键调用`() {
        val script = LocationScroll.script(0)
        // 少任何一个都会失去定位能力，且失败是静默的，故断言关键片段存在
        assertTrue(script.contains("window.scrollTo"))
        assertTrue(script.contains("createTreeWalker"))
        assertTrue(script.contains("createRange"))
    }

    @Test
    fun `负偏移夹紧为 0`() {
        assertTrue(LocationScroll.script(-5).contains("})(0)"))
    }

    @Test
    fun `超大偏移夹紧为上限`() {
        val script = LocationScroll.script(Int.MAX_VALUE)
        assertTrue(script.contains("})(${LocationScroll.MAX_OFFSET})"))
        assertEquals(10_000_000, LocationScroll.MAX_OFFSET)
    }
}
