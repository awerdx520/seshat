package com.seshat.app.gtd

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [OrgSearchMatcher] 的纯 JVM 单测（不依赖 Android 框架）。 */
class OrgSearchMatcherTest {

    private fun entry(
        level: Int,
        title: String,
        body: String = "",
    ): OrgEntry = OrgEntry(
        level = level,
        title = title,
        todoState = null,
        priority = null,
        tags = emptyList(),
        scheduled = null,
        deadline = null,
        body = body,
    )

    @Test
    fun matches_titleHitIsCaseInsensitive() {
        assertTrue(OrgSearchMatcher.matches(entry(1, "GTD agenda"), "gtd"))
        assertTrue(OrgSearchMatcher.matches(entry(1, "gtd agenda"), "GTD"))
    }

    @Test
    fun matches_bodyHit() {
        assertTrue(OrgSearchMatcher.matches(entry(1, "标题", body = "正文里提到 Seshat"), "seshat"))
    }

    @Test
    fun matches_chineseSubstring() {
        assertTrue(OrgSearchMatcher.matches(entry(1, "阅读《新赤脚医生手册》"), "赤脚医生"))
    }

    @Test
    fun matches_noHit_returnsFalse() {
        assertFalse(OrgSearchMatcher.matches(entry(1, "A", body = "B"), "zenith"))
    }

    @Test
    fun match_titleAndBodyBothHit_returnsIndexOnce() {
        val roots = OrgTreeBuilder.build(
            listOf(entry(1, "meeting"), entry(2, "sub", body = "meeting notes")),
        )

        assertEquals(setOf(0, 1), OrgSearchMatcher.match(roots, "meeting"))
    }

    @Test
    fun match_blankQuery_returnsEmptySet() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A")))

        assertTrue(OrgSearchMatcher.match(roots, "").isEmpty())
        assertTrue(OrgSearchMatcher.match(roots, "   ").isEmpty())
    }

    @Test
    fun match_noHit_returnsEmptySet() {
        val roots = OrgTreeBuilder.build(listOf(entry(1, "A"), entry(2, "B")))

        assertTrue(OrgSearchMatcher.match(roots, "zzz").isEmpty())
    }

    @Test
    fun match_searchesDeepNodes() {
        val roots = OrgTreeBuilder.build(
            listOf(entry(1, "A"), entry(2, "B"), entry(3, "深层标题")),
        )

        assertEquals(setOf(2), OrgSearchMatcher.match(roots, "深层"))
    }
}
