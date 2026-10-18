package com.seshat.app.notes.render

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** [HtmlDocument] 的纯 JVM 单测（只断言字符串结构，不依赖 Android 框架）。 */
class HtmlDocumentTest {

    @Test
    fun wrap_producesFullDocumentWithArticle() {
        val html = HtmlDocument.wrap("<p>正文</p>")

        assertTrue(html.startsWith("<!DOCTYPE html>"))
        assertTrue(html.contains("<article>"))
        assertTrue(html.contains("</article>"))
        assertTrue(html.contains("<meta charset=\"utf-8\">"))
        assertTrue(html.contains("initial-scale=1"))
    }

    @Test
    fun wrap_includesDarkModeMediaQuery() {
        val html = HtmlDocument.wrap("")

        assertTrue(html.contains("prefers-color-scheme:dark") || html.contains("prefers-color-scheme: dark"))
        assertTrue(html.contains("@media"))
    }

    @Test
    fun wrap_keepsBodyHtmlVerbatimInsideArticle() {
        val body = "<h1>标题</h1><p>带 <code>代码</code> 与 &amp; 转义</p>"

        val html = HtmlDocument.wrap(body)

        val start = html.indexOf("<article>") + "<article>".length
        val end = html.indexOf("</article>")
        assertEquals(body, html.substring(start, end))
    }

    @Test
    fun wrap_cssCoversReaderTypographyAndNoteClasses() {
        val css = HtmlDocument.wrap("")

        // 代码块横向滚动 + 等宽字体
        assertTrue(css.contains("overflow-x:auto") || css.contains("overflow-x: auto"))
        assertTrue(css.contains("monospace"))
        // 标题递减字号：h1 到 h6 至少各出现一次选择器
        (1..6).forEach { level -> assertTrue(css.contains("h$level")) }
        // 引用左边框
        assertTrue(css.contains("blockquote"))
        // 渲染器产出的类名样式
        listOf(".todo", ".todo-done", ".priority", ".tags", ".planning", ".properties")
            .forEach { cls -> assertTrue("缺少样式：$cls", css.contains(cls)) }
        // 正文版式与链接颜色
        assertTrue(css.contains("line-height"))
        assertTrue(css.contains("padding"))
        assertTrue(css.contains("a"))
    }
}
