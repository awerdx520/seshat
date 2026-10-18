package com.seshat.app.notes.render

import com.seshat.app.notes.render.RenderSupport.Flavor

/**
 * markdown 文本 → HTML 片段（**不含** `<html>` 外壳，外壳由 HtmlDocument 负责）。
 *
 * 纯 JVM 实现（**不得**引用任何 Android 框架类），与 [OrgHtmlRenderer] 共享
 * [RenderSupport] 的行内解析、列表栈、段落累积器。
 *
 * 支持范围（刻意只做「笔记阅读」够用的子集，未识别的语法按普通段落输出）：
 * 1. ATX 标题 `#`~`######`（闭标记 `## 标题 ##` 会剥掉，词内 `C#` 保留）；
 * 2. 行内：`` `代码` ``、`**粗**`、`*斜*`、`~~删除~~`、`[文字](url)`（走 [RenderSupport.inline]）；
 * 3. 列表：`-` `*` `+`（无序）、`1.` `1)`（有序），2 空格缩进一层嵌套；
 * 4. 围栏代码块 ```` ```lang ````（内容只转义、不解析；未闭合则余下内容全当代码）；
 * 5. 引用 `> …`（连续多行合并，内部递归按块渲染）；
 * 6. 水平线 `---` / `***` / `___`（整行 ≥3 个同一字符）；
 * 7. 段落：连续非空行合并 `<p>`（行间 `<br>`），空行分段；
 * 8. 表格 `|a|b|` **不**渲染为 `<table>`，按普通段落输出。
 */
internal object MarkdownHtmlRenderer {

    /** ATX 标题：`#`~`######` 后必须跟空白（避免把 `#标签` 当标题）。 */
    private val HEADING = Regex("^(#{1,6})\\s+(.*)$")

    /** ATX 闭标记：空白 + `#` 序列到行尾；`C#` 这类词内 `#` 不匹配（前面没有空白）。 */
    private val HEADING_CLOSE = Regex("\\s+#+\\s*$")

    /** 围栏起点：` ```lang `（反引号后可跟语言标识）。 */
    private val FENCE_OPEN = Regex("^```\\s*([^`]*)$")

    /** 围栏终点：整行只有反引号（允许行尾空白）。 */
    private val FENCE_CLOSE = Regex("^```\\s*$")

    /** 引用行：`> 内容` 或 `>`（空引用行）。 */
    private val QUOTE = Regex("^>\\s?(.*)$")

    /** 无序列表项（保留行首缩进用于判层级；`[ *+-]` 后必须有空白，故 `---` 不算列表）。 */
    private val UNORDERED_ITEM = Regex("^( *)[-*+]\\s+(.*)$")

    /** 有序列表项：`1. ` / `1) `。 */
    private val ORDERED_ITEM = Regex("^( *)\\d+[.)]\\s+(.*)$")

    /** 水平线：整行 3 个以上**同一**字符（`-` / `*` / `_`），最多 3 个前导空格。 */
    private val HORIZONTAL_RULE = Regex("^ {0,3}([-*_])\\1{2,}\\s*$")

    /** markdown 文本 → HTML 片段。 */
    fun render(text: String): String {
        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val out = StringBuilder()
        // 列表栈与段落累积器与 org 渲染器共用（见 RenderSupport）
        val lists = RenderSupport.ListStack(out)
        val paragraphs = RenderSupport.ParagraphBuffer(out, Flavor.MARKDOWN)

        /** 块边界统一收尾：段落先输出，再闭合列表，保证标签配平。 */
        fun flushAll() {
            paragraphs.flush()
            lists.closeAll()
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index].trimEnd()
            val trimmed = line.trim()

            // ---------- 围栏代码块 ----------
            val fence = FENCE_OPEN.matchEntire(trimmed)
            if (fence != null) {
                flushAll()
                val language = fence.groupValues[1].trim()
                val body = ArrayList<String>()
                var cursor = index + 1
                while (cursor < lines.size && !FENCE_CLOSE.matches(lines[cursor].trim())) {
                    body.add(lines[cursor])
                    cursor++
                }
                // 未闭合的围栏：余下内容全部当代码（宁可朴素，不可崩溃、不可丢内容）
                index = if (cursor < lines.size) cursor + 1 else lines.size
                out.append(codeBlock(language, body))
                continue
            }

            // ---------- 空行：分段 ----------
            if (trimmed.isEmpty()) {
                flushAll()
                index++
                continue
            }

            // ---------- 标题 ----------
            val heading = HEADING.matchEntire(trimmed)
            if (heading != null) {
                flushAll()
                val level = heading.groupValues[1].length
                val body = heading.groupValues[2].replace(HEADING_CLOSE, "").trim()
                out.append("<h").append(level).append(">")
                out.append(RenderSupport.inline(body, Flavor.MARKDOWN))
                out.append("</h").append(level).append(">")
                index++
                continue
            }

            // ---------- 水平线（必须早于列表：`---` 不能被当成 `-` 列表项） ----------
            if (HORIZONTAL_RULE.matches(trimmed)) {
                flushAll()
                out.append("<hr>")
                index++
                continue
            }

            // ---------- 引用：连续 `>` 行合并，内部递归渲染 ----------
            if (QUOTE.matches(trimmed)) {
                flushAll()
                val inner = ArrayList<String>()
                var cursor = index
                while (cursor < lines.size) {
                    val quoted = QUOTE.matchEntire(lines[cursor].trim()) ?: break
                    inner.add(quoted.groupValues[1])
                    cursor++
                }
                out.append("<blockquote>").append(render(inner.joinToString("\n"))).append("</blockquote>")
                index = cursor
                continue
            }

            // ---------- 列表项 ----------
            val unordered = UNORDERED_ITEM.matchEntire(line)
            val ordered = if (unordered == null) ORDERED_ITEM.matchEntire(line) else null
            val item = unordered ?: ordered
            if (item != null) {
                paragraphs.flush()
                lists.append(
                    ordered != null,
                    item.groupValues[1].length,
                    RenderSupport.inline(item.groupValues[2].trim(), Flavor.MARKDOWN),
                )
                index++
                continue
            }

            // ---------- 段落（表格行 `|a|b|` 也走这里，保留原字符） ----------
            // 列表必须以非列表行终止：先闭合列表，段落才不会被写进 <li> 内部
            lists.closeAll()
            paragraphs.add(trimmed)
            index++
        }

        flushAll()
        return out.toString()
    }

    /** 代码块：内容只转义、不解析任何行内语法；无语言则不输出 class。 */
    private fun codeBlock(language: String, body: List<String>): String {
        val cls = if (language.isEmpty()) "" else " class=\"language-${RenderSupport.escape(language)}\""
        return "<pre><code" + cls + ">" + RenderSupport.escape(body.joinToString("\n")) + "</code></pre>"
    }
}
