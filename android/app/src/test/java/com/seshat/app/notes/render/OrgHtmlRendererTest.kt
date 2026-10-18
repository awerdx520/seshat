package com.seshat.app.notes.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [OrgHtmlRenderer] 的纯 JVM 单测：只断言「输入文本 → 输出 HTML 片段」的字符串契约。
 *
 * 断言风格：需要锁定完整结构的用例用 [assertEquals]，需要容忍标签内部细节的
 * 用例用 contains 断言（避免把实现细节写死到测试里）。
 */
class OrgHtmlRendererTest {

    private fun render(text: String): String = OrgHtmlRenderer.render(text)

    // ---------- 1. 标题 ----------

    @Test
    fun headings_oneToFiveStarsMapToH1ToH5() {
        assertEquals("<h1>一级</h1>", render("* 一级"))
        assertEquals("<h2>二级</h2>", render("** 二级"))
        assertEquals("<h3>三级</h3>", render("*** 三级"))
        assertEquals("<h4>四级</h4>", render("**** 四级"))
        assertEquals("<h5>五级</h5>", render("***** 五级"))
    }

    @Test
    fun headings_sixStarsClampedToH5() {
        assertEquals("<h5>六级</h5>", render("****** 六级"))
    }

    // ---------- 2. TODO 关键字 ----------

    @Test
    fun heading_todoKeywordColoredAndDoneHasDifferentClass() {
        val todo = render("* TODO 写报告")
        val done = render("* DONE 写报告")

        assertTrue(todo, todo.contains("<span class=\"todo\">TODO</span>"))
        assertTrue(done, done.contains("<span class=\"todo todo-done\">DONE</span>"))
        // DONE 与 TODO 的 class 必须不同，否则 CSS 无法区分
        assertFalse(done, done.contains("<span class=\"todo\">DONE</span>"))
    }

    @Test
    fun heading_priorityAndTagsExtracted() {
        val html = render("* TODO [#A] 写报告 :work:urgent:")

        assertTrue(html, html.contains("<span class=\"priority\">[#A]</span>"))
        assertTrue(html, html.contains("<span class=\"tags\">:work:urgent:</span>"))
        assertTrue(html, html.contains("写报告"))
        assertTrue(html, html.startsWith("<h1>"))
        assertTrue(html, html.endsWith("</h1>"))
    }

    // ---------- 3~6. 行内强调 ----------

    @Test
    fun inline_bold() {
        assertEquals("<p>这是 <strong>粗</strong> 体</p>", render("这是 *粗* 体"))
    }

    @Test
    fun inline_italicSlashAndUnderscore() {
        assertEquals("<p>这是 <em>斜</em> 体</p>", render("这是 /斜/ 体"))
        assertEquals("<p>这是 <em>下</em> 线</p>", render("这是 _下_ 线"))
    }

    @Test
    fun inline_monospaceEquals() {
        assertEquals("<p>用 <code>code</code> 表示</p>", render("用 =code= 表示"))
    }

    @Test
    fun inline_codeTilde() {
        assertEquals("<p>用 <code>x</code> 表示</p>", render("用 ~x~ 表示"))
    }

    @Test
    fun inline_strikeThrough() {
        assertEquals("<p>这是 <del>删</del> 除</p>", render("这是 +删+ 除"))
    }

    @Test
    fun inline_slashMarkerDoesNotEatUrl() {
        // `/斜/` 规则必须把 `http://x/a/` 原样保留（不允许生成 <em>）
        val html = render("见 http://example.com/a/ 路径")

        assertFalse(html, html.contains("<em>"))
        assertTrue(html, html.contains("http://example.com/a/"))
    }

    // ---------- 7~9. 列表 ----------

    @Test
    fun list_unordered() {
        assertEquals("<ul><li>a</li><li>b</li></ul>", render("- a\n- b"))
        assertEquals("<ul><li>a</li><li>b</li></ul>", render("+ a\n+ b"))
    }

    @Test
    fun list_ordered() {
        assertEquals("<ol><li>a</li><li>b</li></ol>", render("1. a\n2. b"))
        assertEquals("<ol><li>a</li><li>b</li></ol>", render("1) a\n2) b"))
    }

    @Test
    fun list_nestedByTwoSpaceIndent() {
        assertEquals(
            "<ul><li>a<ul><li>b</li></ul></li></ul>",
            render("- a\n  - b"),
        )
    }

    @Test
    fun list_terminatedByFollowingParagraph() {
        // 列表后紧跟段落行（无空行）时，段落不得被写进 <li> 内部
        assertEquals("<ul><li>a</li></ul><p>正文</p>", render("- a\n正文"))
    }

    // ---------- 10. 代码块 ----------

    @Test
    fun codeBlock_srcWithLanguageAndEscapedContent() {
        val html = render("#+BEGIN_SRC kotlin\nval a = \"<script>\"\n#+END_SRC")

        assertTrue(html, html.contains("<pre><code class=\"language-kotlin\">"))
        assertTrue(html, html.contains("&lt;script&gt;"))
        assertFalse(html, html.contains("<script>"))
        assertTrue(html, html.contains("</code></pre>"))
    }

    @Test
    fun codeBlock_exampleHasNoLanguageClass() {
        val html = render("#+BEGIN_EXAMPLE\na < b\n#+END_EXAMPLE")

        assertTrue(html, html.contains("<pre><code>"))
        assertTrue(html, html.contains("a &lt; b"))
    }

    // ---------- 11. 引用 ----------

    @Test
    fun quote_blockRendersParagraphInside() {
        assertEquals(
            "<blockquote><p>引用 <strong>文字</strong></p></blockquote>",
            render("#+BEGIN_QUOTE\n引用 *文字*\n#+END_QUOTE"),
        )
    }

    // ---------- 12. 链接 ----------

    @Test
    fun link_bothForms() {
        assertEquals(
            "<p><a href=\"https://example.com\">示例</a></p>",
            render("[[https://example.com][示例]]"),
        )
        assertEquals(
            "<p><a href=\"https://example.com\">https://example.com</a></p>",
            render("[[https://example.com]]"),
        )
    }

    @Test
    fun link_unsafeSchemeDegradedToPlainText() {
        val html = render("[[javascript:alert(1)][点我]]")

        assertFalse(html, html.contains("<a "))
        assertTrue(html, html.contains("点我"))
    }

    // ---------- 13. PROPERTIES 抽屉 ----------

    @Test
    fun propertiesDrawerRenderedAsDetails() {
        val html = render(":PROPERTIES:\n:ID: abc-123\n:END:")

        assertTrue(html, html.contains("<details><summary>属性</summary>"))
        assertTrue(html, html.contains("<pre class=\"properties\">"))
        assertTrue(html, html.contains(":ID: abc-123"))
        assertTrue(html, html.contains("</details>"))
    }

    // ---------- 14. 关键字行 ----------

    @Test
    fun keywordLinesSkipped() {
        val html = render("#+TITLE: 我的笔记\n#+FILETAGS: :a:b:\n#+AUTHOR: 某人\n正文")

        assertFalse(html, html.contains("#+TITLE"))
        assertFalse(html, html.contains("我的笔记"))
        assertFalse(html, html.contains("某人"))
        assertEquals("<p>正文</p>", html)
    }

    // ---------- 15. HTML 转义 ----------

    @Test
    fun htmlEscapedBeforeEmphasis() {
        val html = render("*<script>alert(1)</script>*")

        assertFalse(html, html.contains("<script"))
        assertTrue(html, html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        assertTrue(html, html.contains("<strong>"))
    }

    // ---------- 16. 表格不做 ----------

    @Test
    fun tableLinesRenderedAsParagraphText() {
        val html = render("|a|b|\n|1|2|")

        assertFalse(html, html.contains("<table"))
        assertEquals("<p>|a|b|<br>|1|2|</p>", html)
    }

    // ---------- 补充：计划行 / 段落合并 ----------

    @Test
    fun planningLineKeptVisible() {
        assertEquals(
            "<p class=\"planning\">DEADLINE: &lt;2026-10-20 周三&gt;</p>",
            render("DEADLINE: <2026-10-20 周三>"),
        )
    }

    @Test
    fun paragraphsMergeConsecutiveLinesAndSplitOnBlank() {
        assertEquals("<p>第一行<br>第二行</p>", render("第一行\n第二行"))
        assertEquals("<p>a</p><p>b</p>", render("a\n\nb"))
    }

    @Test
    fun emptyInputProducesEmptyOutput() {
        assertEquals("", render(""))
        assertEquals("", render("\n\n"))
    }
}
