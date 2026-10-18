package com.seshat.app.notes.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [MarkdownHtmlRenderer] 的纯 JVM 单测：只断言「markdown 文本 → 输出 HTML 片段」的字符串契约。
 *
 * 断言风格与 [OrgHtmlRendererTest] 一致：需要锁定完整结构时用 [assertEquals]，
 * 需要容忍标签内部细节（如属性顺序）时用 contains 断言。
 */
class MarkdownHtmlRendererTest {

    private fun render(text: String): String = MarkdownHtmlRenderer.render(text)

    // ---------- 1. ATX 标题（1~6 级） ----------

    @Test
    fun headings_sixLevelsMapToH1ToH6() {
        assertEquals("<h1>一级</h1>", render("# 一级"))
        assertEquals("<h2>二级</h2>", render("## 二级"))
        assertEquals("<h3>三级</h3>", render("### 三级"))
        assertEquals("<h4>四级</h4>", render("#### 四级"))
        assertEquals("<h5>五级</h5>", render("##### 五级"))
        assertEquals("<h6>六级</h6>", render("###### 六级"))
    }

    @Test
    fun heading_trailingHashesStripped() {
        assertEquals("<h2>标题</h2>", render("## 标题 ##"))
        // 词内的 `#` 不是闭标记，必须保留
        assertEquals("<h1>C#</h1>", render("# C#"))
        // 7 个 `#` 不是 ATX 标题（CommonMark 上限 6 级）→ 按普通段落
        assertEquals("<p>####### 太深</p>", render("####### 太深"))
    }

    // ---------- 2~5. 行内强调（走 RenderSupport.inline(MARKDOWN)） ----------

    @Test
    fun inline_bold() {
        assertEquals("<p>这是 <strong>粗</strong> 体</p>", render("这是 **粗** 体"))
    }

    @Test
    fun inline_italic() {
        assertEquals("<p>这是 <em>斜</em> 体</p>", render("这是 *斜* 体"))
    }

    @Test
    fun inline_codeContentIsNotParsed() {
        val html = render("用 `*x*` 表示")

        assertEquals("<p>用 <code>*x*</code> 表示</p>", html)
        assertFalse(html, html.contains("<em>"))
    }

    @Test
    fun inline_strikethrough() {
        assertEquals("<p>这是 <del>删</del> 除</p>", render("这是 ~~删~~ 除"))
    }

    // ---------- 6~8. 列表 ----------

    @Test
    fun list_unorderedThreeMarkers() {
        assertEquals("<ul><li>a</li><li>b</li></ul>", render("- a\n- b"))
        assertEquals("<ul><li>a</li><li>b</li></ul>", render("* a\n* b"))
        assertEquals("<ul><li>a</li><li>b</li></ul>", render("+ a\n+ b"))
    }

    @Test
    fun list_orderedTwoMarkers() {
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

    // ---------- 9. 围栏代码块 ----------

    @Test
    fun codeFence_withLanguageAndEscapedContent() {
        val html = render("```kotlin\nval a = \"<script>\"\n```")

        assertTrue(html, html.contains("<pre><code class=\"language-kotlin\">"))
        assertTrue(html, html.contains("&lt;script&gt;"))
        assertFalse(html, html.contains("<script>"))
        assertTrue(html, html.contains("</code></pre>"))
    }

    @Test
    fun codeFence_withoutLanguageHasNoClass() {
        val html = render("```\na < b\n```")

        assertTrue(html, html.contains("<pre><code>"))
        assertTrue(html, html.contains("a &lt; b"))
        assertFalse(html, html.contains("class="))
    }

    @Test
    fun codeFence_unclosedTreatsRestAsCode() {
        val html = render("```\nabc\n**不解析**")

        assertEquals("<pre><code>abc\n**不解析**</code></pre>", html)
    }

    // ---------- 10. 行内链接 ----------

    @Test
    fun link_inlineSafeRendered() {
        assertEquals(
            "<p><a href=\"https://example.com\">示例</a></p>",
            render("[示例](https://example.com)"),
        )
    }

    @Test
    fun link_inlineUnsafeSchemeDegradedToPlainText() {
        val html = render("[点我](javascript:alert(1))")

        assertFalse(html, html.contains("<a"))
        assertTrue(html, html.contains("点我"))
    }

    // ---------- 11. 引用 ----------

    @Test
    fun quote_rendersParagraphInside() {
        assertEquals(
            "<blockquote><p>引用 <strong>文字</strong></p></blockquote>",
            render("> 引用 **文字**"),
        )
    }

    @Test
    fun quote_multipleLinesMergedIntoOneParagraph() {
        assertEquals(
            "<blockquote><p>第一行<br>第二行</p></blockquote>",
            render("> 第一行\n> 第二行"),
        )
    }

    // ---------- 11b. 引用内部再嵌块（递归渲染） ----------

    @Test
    fun quote_containingListUsesNestedRenderer() {
        assertEquals(
            "<blockquote><ul><li>a</li><li>b</li></ul></blockquote>",
            render("> - a\n> - b"),
        )
    }

    @Test
    fun quote_containingFenceRendersCodeBlockInside() {
        val html = render("> ```\n> a < b\n> ```")

        assertTrue(html, html.startsWith("<blockquote><pre><code>"))
        assertTrue(html, html.contains("a &lt; b"))
        assertTrue(html, html.endsWith("</code></pre></blockquote>"))
    }

    // ---------- 12. 水平线 ----------

    @Test
    fun horizontalRule_threeFormsAndSplitsParagraphs() {
        assertEquals("<hr>", render("---"))
        assertEquals("<hr>", render("***"))
        assertEquals("<hr>", render("___"))
        assertEquals("<p>a</p><hr><p>b</p>", render("a\n\n---\n\nb"))
    }

    // ---------- 13. 表格不做 ----------

    @Test
    fun tableLinesRenderedAsParagraphText() {
        val html = render("|a|b|\n|1|2|")

        assertFalse(html, html.contains("<table"))
        assertEquals("<p>|a|b|<br>|1|2|</p>", html)
    }

    // ---------- 14. HTML 安全 ----------

    @Test
    fun htmlEscapedBeforeEmphasis() {
        val html = render("**<script>alert(1)</script>**")

        assertFalse(html, html.contains("<script"))
        assertTrue(html, html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        assertTrue(html, html.contains("<strong>"))
    }

    @Test
    fun htmlTagLikeTextInParagraphEscaped() {
        assertEquals("<p>&lt;div&gt;</p>", render("<div>"))
    }

    @Test
    fun inline_greaterThanNotAtLineStartIsNotAQuote() {
        // 段落中间/行首非 `>` 开头的 `>` 必须转义，且不触发 blockquote
        assertEquals("<p>a &gt; b &amp; c</p>", render("a > b & c"))
    }

    // ---------- 补充：段落合并 / 空输入 ----------

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
