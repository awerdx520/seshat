package com.seshat.app.notes

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** [DenoteName] 的纯 JVM 单测（不依赖 Android 框架）。 */
class DenoteNameTest {

    // ---------- 命中 ----------

    @Test
    fun parse_denoteWithoutTags() {
        val parsed = DenoteName.parse("20240101T120000--我的笔记.org")

        assertEquals("我的笔记", parsed?.title)
        assertEquals(emptyList<String>(), parsed?.tags)
    }

    @Test
    fun parse_denoteWithTwoTags() {
        val parsed = DenoteName.parse("20240101T120000--我的笔记__tag1_tag2.org")

        assertEquals("我的笔记", parsed?.title)
        assertEquals(listOf("tag1", "tag2"), parsed?.tags)
    }

    @Test
    fun parse_singleChineseTag() {
        val parsed = DenoteName.parse("20240101T120000--标题__单标签.md")

        assertEquals("标题", parsed?.title)
        assertEquals(listOf("单标签"), parsed?.tags)
    }

    @Test
    fun parse_uppercaseExtension() {
        val parsed = DenoteName.parse("20240101T120000--x.MD")

        assertEquals("x", parsed?.title)
        assertEquals(emptyList<String>(), parsed?.tags)
    }

    @Test
    fun parse_titleKeepsUnderscoresAsIs() {
        // 标题内的单个下划线不替换为空格，保持原样
        val parsed = DenoteName.parse("20240101T120000--a_b.org")

        assertEquals("a_b", parsed?.title)
        assertEquals(emptyList<String>(), parsed?.tags)
    }

    // ---------- 未命中 ----------

    @Test
    fun parse_nonDenoteNameReturnsNull() {
        assertNull(DenoteName.parse("notes.org"))
    }

    @Test
    fun parse_missingTimestampReturnsNull() {
        assertNull(DenoteName.parse("--标题.org"))
    }

    @Test
    fun parse_emptyTitleReturnsNull() {
        assertNull(DenoteName.parse("20240101T120000--__a.org"))
    }

    @Test
    fun parse_unsupportedExtensionReturnsNull() {
        assertNull(DenoteName.parse("20240101T120000--标题.txt"))
    }

    // ---------- 边界：连续下划线 ----------

    @Test
    fun parse_consecutiveUnderscoreInTagSection() {
        // 标题取第一个 `__` 之前；标签段按 `_` 分割后过滤空串
        val parsed = DenoteName.parse("20240101T120000--标题__a__b.org")

        assertEquals("标题", parsed?.title)
        assertEquals(listOf("a", "b"), parsed?.tags)
    }
}
