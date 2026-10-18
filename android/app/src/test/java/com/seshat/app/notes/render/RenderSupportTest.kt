package com.seshat.app.notes.render

import com.seshat.app.notes.render.RenderSupport.Flavor
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/** [RenderSupport] 的纯 JVM 单测：转义、URL 白名单、行内代码占位、行内强调。 */
class RenderSupportTest {

    // ---------- 1. escape ----------

    @Test
    fun escape_fiveCharacters() {
        assertEquals(
            "&lt;a href=&quot;x&quot;&gt;&amp;&#39;&lt;/a&gt;",
            RenderSupport.escape("<a href=\"x\">&'</a>"),
        )
    }

    // ---------- 2. URL 白名单 ----------

    @Test
    fun isSafeUrl_onlyHttpHttpsMailto() {
        assertTrue(RenderSupport.isSafeUrl("http://example.com/a"))
        assertTrue(RenderSupport.isSafeUrl("https://example.com"))
        assertTrue(RenderSupport.isSafeUrl("mailto:someone@example.com"))
        assertTrue(RenderSupport.isSafeUrl("HTTPS://EXAMPLE.COM"))

        assertFalse(RenderSupport.isSafeUrl("javascript:alert(1)"))
        assertFalse(RenderSupport.isSafeUrl("file:///etc/passwd"))
        assertFalse(RenderSupport.isSafeUrl("data:text/html,<b>x</b>"))
        assertFalse(RenderSupport.isSafeUrl("example.com/no-scheme"))
        assertFalse(RenderSupport.isSafeUrl(""))
    }

    // ---------- 3. 行内代码占位（内容不再解析） ----------

    @Test
    fun inline_codeContentIsNotParsedFurther() {
        assertEquals("<code>*x*</code>", RenderSupport.inline("~*x*~", Flavor.ORG))
        assertEquals("<code>*x*</code>", RenderSupport.inline("=*x*=", Flavor.ORG))
        assertEquals("<code>*x*</code>", RenderSupport.inline("`*x*`", Flavor.MARKDOWN))
    }

    @Test
    fun inline_codeContentStillEscaped() {
        assertEquals(
            "<code>&lt;b&gt;</code>",
            RenderSupport.inline("~<b>~", Flavor.ORG),
        )
    }

    // ---------- 4. link 降级 ----------

    @Test
    fun link_unsafeUrlDegradedToPlainText() {
        val html = RenderSupport.link("javascript:alert(1)", "点我")

        assertFalse(html, html.contains("<a "))
        assertEquals("点我", html)
    }

    @Test
    fun link_safeUrlRenderedAsAnchor() {
        assertEquals(
            "<a href=\"https://example.com\">示例</a>",
            RenderSupport.link("https://example.com", "示例"),
        )
    }

    // ---------- 5. `**` 二义性（方言差异锁定） ----------

    @Test
    fun doubleStarIsLiteralInOrgButBoldInMarkdown() {
        assertEquals("**x**", RenderSupport.inline("**x**", Flavor.ORG))
        assertEquals("<strong>x</strong>", RenderSupport.inline("**x**", Flavor.MARKDOWN))
    }

    // ---------- 6. 强调基本形态 ----------

    @Test
    fun inline_emphasisPerFlavor() {
        assertEquals("<strong>x</strong>", RenderSupport.inline("*x*", Flavor.ORG))
        assertEquals("<em>x</em>", RenderSupport.inline("/x/", Flavor.ORG))
        assertEquals("<em>x</em>", RenderSupport.inline("_x_", Flavor.ORG))
        assertEquals("<del>x</del>", RenderSupport.inline("+x+", Flavor.ORG))
        assertEquals("<strong>x</strong>", RenderSupport.inline("**x**", Flavor.MARKDOWN))
        assertEquals("<em>x</em>", RenderSupport.inline("*x*", Flavor.MARKDOWN))
        assertEquals("<del>x</del>", RenderSupport.inline("~~x~~", Flavor.MARKDOWN))
    }
}
