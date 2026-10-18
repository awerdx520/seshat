package com.seshat.app.gtd

/**
 * org 文本的「按条目标题行」改写器（纯 JVM 逻辑，不依赖 Android 框架）。
 *
 * 与 [OrgParser] 共用同一套标题行识别规则（`^\*+(\s+内容)?$`）与 TODO 关键字集合
 * （[OrgParser.DEFAULT_TODO_KEYWORDS]），因此「条目序号」在解析与改写之间保持一致：
 * [headlineLineOf] 返回的第 n 个标题行，恰是 [OrgParser.parse] 得到的第 n 个 [OrgEntry]。
 *
 * 改写只在标题行的「TODO 关键字」位置进行：星号数量、优先级 `[#X]`、末尾标签 `:a:b:`、
 * 标题正文与后续 body 一律原样保留。
 */
object OrgEditor {

    /** 标题行匹配：组 1 = 星号串，组 2 = 标题内容（可空，`(?:...)` 不占组号）。 */
    private val HEADLINE_REGEX = Regex("""^(\*+)(?:\s+(.*))?$""")

    /** 判定「现有 TODO 关键字」用，与解析器共用同一集合。 */
    private val TODO_KEYWORDS: Set<String> = OrgParser.DEFAULT_TODO_KEYWORDS

    /**
     * 返回第 [entryIndex] 个条目的 headline 行号（0 起，与 `text.split("\n")` 的索引一致）。
     *
     * 序号与 [OrgParser.parse] 产出的 [OrgDocument.entries] 一一对应（均为标题出现顺序）。
     *
     * @param text       org 源文本。
     * @param entryIndex 条目序号（0 起）。
     * @return 该条目 headline 所在行号（0 起）。
     * @throws IllegalArgumentException 当 [entryIndex] 为负或超过文档标题总数时。
     */
    fun headlineLineOf(text: String, entryIndex: Int): Int {
        require(entryIndex >= 0) { "entryIndex 不能为负：$entryIndex" }
        var seen = 0
        text.split("\n").forEachIndexed { lineIndex, line ->
            if (HEADLINE_REGEX.matchEntire(line) != null) {
                if (seen == entryIndex) return lineIndex
                seen++
            }
        }
        throw IllegalArgumentException("entryIndex 越界：$entryIndex（文档仅有 $seen 个标题）")
    }

    /**
     * 把第 [entryIndex] 个条目的 TODO 状态改写为 [newState]。
     *
     * 定位方式：先经 [headlineLineOf] 找到该条目的 headline 行，再委托 [setTodoState]
     * 仅改写该行的 TODO 关键字。`newState` 为 `null` 表示清除 TODO 关键字。
     *
     * @param text       org 源文本。
     * @param entryIndex 条目序号（0 起），与 [OrgParser] 的解析顺序一致。
     * @param newState   目标状态（如 `"TODO"`、`"DONE"`）；`null` 表示清除。
     * @return 改写后的完整 org 文本（其余行保持不变）。
     * @throws IllegalArgumentException 当 [entryIndex] 越界时。
     */
    fun toggleTodoState(text: String, entryIndex: Int, newState: String?): String {
        val line = headlineLineOf(text, entryIndex)
        return setTodoState(text, line, newState)
    }

    /**
     * 把第 [headlineLineIndex] 行的 TODO 状态改写为 [newState]（0 起行号）。
     *
     * 行内处理：拆出星号串与标题内容 → 若内容最前的空白分隔 token 命中
     * [OrgParser.DEFAULT_TODO_KEYWORDS] 则剥离之 → 在星号后插入 [newState]。
     * 因此 `** TODO [#A] 标题 :tag:` → `** DONE [#A] 标题 :tag:` 只改动 TODO 关键字。
     *
     * @param text             org 源文本。
     * @param headlineLineIndex headline 行号（0 起）。
     * @param newState         目标状态；`null` 表示清除（标题无状态时保持原样）。
     * @return 改写后的完整 org 文本。
     * @throws IllegalArgumentException 当行号越界或该行不是合法 headline 时。
     */
    fun setTodoState(text: String, headlineLineIndex: Int, newState: String?): String {
        val lines = text.split("\n").toMutableList()
        require(headlineLineIndex in lines.indices) {
            "headlineLineIndex 越界：$headlineLineIndex（文档共 ${lines.size} 行）"
        }
        val line = lines[headlineLineIndex]
        val parts = parseHeadline(line)
            ?: throw IllegalArgumentException("第 $headlineLineIndex 行不是有效的 org 标题行：$line")
        // headline 行尾的 `\r`（CRLF 文本）原样保留，只重建行内容。
        lines[headlineLineIndex] = renderHeadline(parts, todoState = newState) + carriageReturn(line)
        return lines.joinToString("\n")
    }

    /**
     * 替换条目的标题文本（保留 level / TODO 状态 / 优先级 / 末尾标签）。
     *
     * @param text     org 源文本。
     * @param entry    目标条目，必须带有效行区间（`startLine >= 0`）。
     * @param newTitle 新标题文本（不含 TODO 关键字 / 优先级 / 标签）。
     * @return 改写后的完整 org 文本（仅目标 headline 行变化）。
     * @throws IllegalArgumentException 当 [OrgEntry.startLine] 无效或该行不是合法 headline 时。
     */
    fun setTitle(text: String, entry: OrgEntry, newTitle: String): String {
        val lines = text.split("\n").toMutableList()
        val index = requireStartLine(entry, lines.size)
        val line = lines[index]
        val parts = parseHeadline(line)
            ?: throw IllegalArgumentException("第 $index 行不是有效的 org 标题行：$line")
        lines[index] = renderHeadline(parts, title = newTitle) + carriageReturn(line)
        return lines.joinToString("\n")
    }

    /**
     * 替换条目的正文（`startLine + 1 .. endLine` 的行）；[newBody] 为空串时删除全部正文行。
     *
     * @param text    org 源文本。
     * @param entry   目标条目，必须带有效行区间。
     * @param newBody 新正文（多行用 `\n` 分隔）。
     * @return 改写后的完整 org 文本（其余行逐字保留）。
     * @throws IllegalArgumentException 当 [OrgEntry.startLine] / [OrgEntry.endLine] 无效时。
     */
    fun setBody(text: String, entry: OrgEntry, newBody: String): String {
        val lines = text.split("\n").toMutableList()
        val range = bodyRange(entry, lines)
        val cr = carriageReturn(lines[range.headline])
        val fresh = bodyLines(newBody, cr, range.eofWithoutNewline)
        // 只替换正文区间内的行；区间外的行（含下一条 headline）逐字保留。
        lines.subList(range.start, range.end).clear()
        lines.addAll(range.start, fresh)
        return lines.joinToString("\n")
    }

    /**
     * 在条目末尾（[OrgEntry.endLine] 之前）插入一个子条目。
     *
     * 子条目 level = `entry.level + 1`，标题为 [childTitle]，正文为 [childBody]（可为空）。
     *
     * @param text       org 源文本。
     * @param entry      父条目，必须带有效行区间。
     * @param childTitle 子条目标题。
     * @param childBody  子条目正文（多行用 `\n` 分隔）；空串表示无正文。
     * @return 改写后的完整 org 文本。
     * @throws IllegalArgumentException 当 [OrgEntry.startLine] / [OrgEntry.endLine] 无效时。
     */
    fun insertChild(
        text: String,
        entry: OrgEntry,
        childTitle: String,
        childBody: String = "",
    ): String {
        val lines = text.split("\n").toMutableList()
        val range = bodyRange(entry, lines)
        val cr = carriageReturn(lines[range.headline])
        val block = mutableListOf(("*".repeat(entry.level + 1) + " " + childTitle.trim()).trimEnd())
        if (childBody.isNotEmpty()) {
            // 子正文每行同样按原文件换行风格补 `\r`（写入前统一剥离，避免出现 `\r\r`）。
            block += childBody.split("\n").map { stripCarriageReturn(it) }
        }
        val withCr = block.mapIndexed { i, line ->
            if (i == block.lastIndex && range.eofWithoutNewline) line else line + cr
        }
        // 插入点在正文区间末尾（即下一条 headline 之前 / 文件末尾）。
        lines.addAll(range.end, withCr)
        return lines.joinToString("\n")
    }

    // ---------------------------------------------------------------- 内部：headline 拆解与重建

    /**
     * headline 行的拆解结果（行尾 `\r` 已被剥离）。
     *
     * @property stars 星号串（即层级）。
     * @property todoState 现有 TODO 关键字；无则 `null`。
     * @property priority 优先级原文（含方括号，如 `[#A]`）；无则 `null`。
     * @property title 纯标题文本。
     * @property tags 末尾标签原文（如 `:a:b:`）；无则空串。
     */
    private data class HeadlineParts(
        val stars: String,
        val todoState: String?,
        val priority: String?,
        val title: String,
        val tags: String,
    )

    /**
     * 拆解 headline 行：顺序与 [OrgParser] 一致（优先级 → 末尾标签 → 最前 TODO 关键字）。
     *
     * 返回 `null` 表示该行不是合法 headline。[OrgEditor.setTodoState] 与 [OrgEditor.setTitle]
     * 共用本函数，避免「拆解 + 重建」逻辑出现两份副本。
     */
    private fun parseHeadline(line: String): HeadlineParts? {
        val match = HEADLINE_REGEX.matchEntire(stripCarriageReturn(line)) ?: return null
        val stars = match.groupValues[1]
        var rest = match.groupValues.getOrElse(2) { "" }.trim()

        // 1) 优先级 [#X]
        var priority: String? = null
        OrgParser.PRIORITY_REGEX.find(rest)?.let { m ->
            priority = m.value
            rest = rest.removeRange(m.range).trim()
        }

        // 2) 末尾标签 :a:b:
        var tags = ""
        OrgParser.TAGS_REGEX.find(rest)?.let { m ->
            tags = m.groupValues[1]
            rest = rest.removeRange(m.range).trim()
        }

        // 3) 最前的 TODO 关键字
        var todo: String? = null
        val firstToken = rest.takeWhile { !it.isWhitespace() }
        if (firstToken.isNotEmpty() && firstToken in TODO_KEYWORDS) {
            todo = firstToken
            rest = rest.substring(firstToken.length).trim()
        }

        return HeadlineParts(stars, todo, priority, rest, tags)
    }

    /**
     * 按「stars [TODO] [优先级] 标题 [标签]」重建 headline 行（不含行尾 `\r`）。
     *
     * [todoState] / [title] 可覆盖 [parts] 中的原值（供 [setTodoState] / [setTitle] 复用）。
     */
    private fun renderHeadline(
        parts: HeadlineParts,
        todoState: String? = parts.todoState,
        title: String = parts.title,
    ): String = buildString {
        append(parts.stars)
        if (!todoState.isNullOrEmpty()) append(' ').append(todoState)
        if (parts.priority != null) append(' ').append(parts.priority)
        val trimmedTitle = title.trim()
        if (trimmedTitle.isNotEmpty()) append(' ').append(trimmedTitle)
        if (parts.tags.isNotEmpty()) append(' ').append(parts.tags)
    }

    // ---------------------------------------------------------------- 内部：行区间解算

    /**
     * 条目正文区间的解算结果。
     *
     * @property headline headline 行号（用于探测该文件的换行风格）。
     * @property start 正文起始行（`headline + 1`）。
     * @property end 正文结束行（exclusive）；若文件以换行结尾，收敛到最后一行的前一行。
     * @property eofWithoutNewline 区间延到文件末尾且文件原本没有结尾换行。
     */
    private class BodyRange(
        val headline: Int,
        val start: Int,
        val end: Int,
        val eofWithoutNewline: Boolean,
    )

    /**
     * 解算 [entry] 的正文区间。
     *
     * `text.split("\n")` 对「以换行结尾」的文件会多出末尾空串元素；插入/替换时若把它算进区间，
     * 会破坏文件结尾形态，故此处收敛一行。
     */
    private fun bodyRange(entry: OrgEntry, lines: List<String>): BodyRange {
        val headline = requireStartLine(entry, lines.size)
        require(entry.endLine in (headline + 1)..lines.size) {
            "条目缺少有效行区间（startLine=${entry.startLine}, endLine=${entry.endLine}）"
        }
        val endsWithNewline = lines.lastOrNull()?.isEmpty() == true
        val atEof = entry.endLine == lines.size
        val end = if (atEof && endsWithNewline) lines.size - 1 else entry.endLine
        return BodyRange(
            headline = headline,
            start = headline + 1,
            end = end,
            eofWithoutNewline = atEof && !endsWithNewline,
        )
    }

    /**
     * 把新内容拆成待插入的行，并按原文件换行风格补行尾 `\r`。
     *
     * [eofWithoutNewline] 为 `true` 时最后一行不补 `\r`，保持「文件末尾无换行」的形态。
     */
    private fun bodyLines(newBody: String, cr: String, eofWithoutNewline: Boolean): List<String> {
        if (newBody.isEmpty()) return emptyList()
        val parts = newBody.split("\n").map { stripCarriageReturn(it) }
        return parts.mapIndexed { i, line ->
            if (i == parts.lastIndex && eofWithoutNewline) line else line + cr
        }
    }

    /** 校验并返回 headline 行号；行区间缺失（`-1`）或越界时抛 [IllegalArgumentException]。 */
    private fun requireStartLine(entry: OrgEntry, lineCount: Int): Int {
        require(entry.startLine in 0 until lineCount) {
            "条目缺少有效行区间（startLine=${entry.startLine}），无法定位 headline 行"
        }
        return entry.startLine
    }

    /** 去掉行尾 `\r`（CRLF 文本按 `split("\n")` 分行后每行都带它）。 */
    private fun stripCarriageReturn(line: String): String =
        if (line.endsWith("\r")) line.dropLast(1) else line

    /** 行尾 `\r`（CRLF 风格）；LF 文本返回空串。 */
    private fun carriageReturn(line: String): String = if (line.endsWith("\r")) "\r" else ""
}
