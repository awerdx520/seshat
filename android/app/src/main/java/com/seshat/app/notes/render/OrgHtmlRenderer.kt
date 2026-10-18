package com.seshat.app.notes.render

import com.seshat.app.notes.render.RenderSupport.Flavor

/**
 * org-mode 文本 → HTML 片段（**不含** `<html>` 外壳，外壳由 HtmlDocument 负责）。
 *
 * 纯 JVM 实现（**不得**引用任何 Android 框架类）。支持范围刻意只做「笔记阅读」够用的
 * 子集：未识别的语法按普通段落输出（宁可朴素，不可崩溃），表格不渲染为 `<table>`。
 *
 * 支持的块级元素：
 * 1. 标题 `*`~`*****`（`******` 以上按 h5）；剥离 TODO 关键字 / `[#A]` 优先级 / 末尾 `:tag:`;
 * 2. 计划行 `DEADLINE:` / `SCHEDULED:` / `CLOSED:`（保留可见）；
 * 3. 列表 `-`/`+`（无序）、`1.`/`1)`（有序），按 2 空格缩进嵌套（最多展开到实际缩进层）；
 * 4. `#+BEGIN_SRC lang` / `#+BEGIN_EXAMPLE` / `#+BEGIN_QUOTE` 块；
 * 5. `:PROPERTIES: … :END:` 抽屉 → 可展开的 `<details>`；
 * 6. `#+TITLE:` 等关键字行跳过；
 * 7. 段落：连续非空行合并为一个 `<p>`（行间 `<br>`），空行分段。
 */
internal object OrgHtmlRenderer {

    /** 标题：`*` 后必须有空格，避免把行首 `*粗*` 误判为标题。 */
    private val HEADING = Regex("^(\\*+)\\s+(.*)$")

    /** TODO 关键字（只在标题起始位置识别）。 */
    private val TODO_KEYWORD = Regex("^(TODO|DONE|NEXT|WAITING|CANCELLED)\\s+")

    /** 优先级 `[#A]`~`[#Z]`。 */
    private val PRIORITY = Regex("^\\[#([A-Za-z])\\]\\s*")

    /** 标题末尾的 `:tag1:tag2:`。 */
    private val TAGS = Regex("\\s*((?::[^\\s:]+)+:)\\s*$")

    /** 计划行（DEADLINE/SCHEDULED/CLOSED）。 */
    private val PLANNING = Regex("^(DEADLINE|SCHEDULED|CLOSED):\\s*(.*)$")

    /** 无序列表项（保留缩进用于判层级）。 */
    private val UNORDERED_ITEM = Regex("^(\\s*)[-+]\\s+(.*)$")

    /** 有序列表项。 */
    private val ORDERED_ITEM = Regex("^(\\s*)\\d+[.)]\\s+(.*)$")

    /** 块起始：`#+BEGIN_XXX [参数]`。 */
    private val BEGIN_BLOCK = Regex("^#\\+BEGIN_([A-Za-z]+)(?:\\s+(.*))?$", RegexOption.IGNORE_CASE)

    /** 关键字行：`#+TITLE:` / `#+FILETAGS:` 等（BEGIN/END 已在此之前单独处理）。 */
    private val KEYWORD_LINE = Regex("^#\\+[A-Za-z_]+:", RegexOption.IGNORE_CASE)

    /** PROPERTIES 抽屉起始。 */
    private const val DRAWER_START = ":PROPERTIES:"

    /** PROPERTIES 抽屉结束。 */
    private const val DRAWER_END = ":END:"

    /** org 文本 → HTML 片段。 */
    fun render(text: String): String {
        val lines = text.replace("\r\n", "\n").replace('\r', '\n').split('\n')
        val out = StringBuilder()
        // 列表栈与段落累积器已上移到 RenderSupport（org / markdown 共用）
        val lists = RenderSupport.ListStack(out)
        val paragraphs = RenderSupport.ParagraphBuffer(out, Flavor.ORG)

        // ---------- 局部状态操作 ----------
        /** 段落与列表一起收尾（块边界调用，保证标签配平、段落不落进 `<li>`）。 */
        fun flushAll() {
            paragraphs.flush()
            lists.closeAll()
        }

        var index = 0
        while (index < lines.size) {
            val line = lines[index].trimEnd()
            val trimmed = line.trim()

            // ---------- 块：#+BEGIN_XXX ... #+END_XXX ----------
            val begin = BEGIN_BLOCK.matchEntire(trimmed)
            if (begin != null) {
                flushAll()
                val kind = begin.groupValues[1].uppercase()
                val arg = begin.groupValues[2].trim()
                val body = ArrayList<String>()
                val endPattern = Regex("^#\\+END_$kind$", RegexOption.IGNORE_CASE)
                var cursor = index + 1
                while (cursor < lines.size && !endPattern.matches(lines[cursor].trim())) {
                    body.add(lines[cursor])
                    cursor++
                }
                index = if (cursor < lines.size) cursor + 1 else lines.size
                out.append(blockHtml(kind, arg, body))
                continue
            }

            // ---------- PROPERTIES 抽屉 ----------
            if (trimmed.equals(DRAWER_START, ignoreCase = true)) {
                flushAll()
                val body = ArrayList<String>()
                var cursor = index + 1
                while (cursor < lines.size && !lines[cursor].trim().equals(DRAWER_END, ignoreCase = true)) {
                    body.add(lines[cursor])
                    cursor++
                }
                index = if (cursor < lines.size) cursor + 1 else lines.size
                out.append("<details><summary>属性</summary><pre class=\"properties\">")
                out.append(RenderSupport.escape(body.joinToString("\n")))
                out.append("</pre></details>")
                continue
            }

            // ---------- 空行：分段 ----------
            if (trimmed.isEmpty()) {
                flushAll()
                index++
                continue
            }

            // ---------- 标题 ----------
            val heading = headingHtml(line)
            if (heading != null) {
                flushAll()
                out.append(heading)
                index++
                continue
            }

            // ---------- 计划行 ----------
            if (PLANNING.matchEntire(trimmed) != null) {
                flushAll()
                out.append("<p class=\"planning\">").append(RenderSupport.escape(trimmed)).append("</p>")
                index++
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
                    RenderSupport.inline(item.groupValues[2].trim(), Flavor.ORG),
                )
                index++
                continue
            }

            // ---------- 关键字行：跳过 ----------
            if (KEYWORD_LINE.containsMatchIn(trimmed)) {
                flushAll()
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

    /** 渲染标题行；不是标题返回 `null`。 */
    private fun headingHtml(line: String): String? {
        val match = HEADING.matchEntire(line) ?: return null
        val level = match.groupValues[1].length.coerceIn(1, 5)
        var rest = match.groupValues[2]
        val head = StringBuilder()

        val todo = TODO_KEYWORD.find(rest)
        if (todo != null) {
            val keyword = todo.groupValues[1]
            val css = if (keyword == "DONE") "todo todo-done" else "todo"
            head.append("<span class=\"").append(css).append("\">").append(keyword).append("</span> ")
            rest = rest.substring(todo.range.last + 1)
        }

        val priority = PRIORITY.find(rest)
        if (priority != null) {
            head.append("<span class=\"priority\">[#")
                .append(priority.groupValues[1])
                .append("]</span> ")
            rest = rest.substring(priority.range.last + 1)
        }

        var tagsHtml = ""
        val tags = TAGS.find(rest)
        if (tags != null) {
            tagsHtml = " <span class=\"tags\">" + RenderSupport.escape(tags.groupValues[1]) + "</span>"
            rest = rest.substring(0, tags.range.first)
        }

        val body = RenderSupport.inline(rest.trim(), Flavor.ORG)
        return "<h$level>" + head + body + tagsHtml + "</h$level>"
    }

    /** 渲染 `#+BEGIN_XXX` 块：SRC/EXAMPLE 走 `<pre><code>`，QUOTE 走 `<blockquote>`。 */
    private fun blockHtml(kind: String, arg: String, body: List<String>): String = when (kind) {
        "SRC" -> codeBlock(arg, body)
        "EXAMPLE" -> codeBlock("", body)
        "QUOTE" -> "<blockquote>" + render(body.joinToString("\n")) + "</blockquote>"
        else -> codeBlock("", body) // 未识别块：按纯文本块输出，保证「不崩溃、不丢内容」
    }

    /** 代码块：内容只转义、不解析任何行内语法。 */
    private fun codeBlock(language: String, body: List<String>): String {
        val cls = if (language.isEmpty()) "" else " class=\"language-${RenderSupport.escape(language)}\""
        return "<pre><code" + cls + ">" + RenderSupport.escape(body.joinToString("\n")) + "</code></pre>"
    }
}
