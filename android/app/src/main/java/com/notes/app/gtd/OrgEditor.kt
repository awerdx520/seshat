package com.notes.app.gtd

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
        val match = HEADLINE_REGEX.matchEntire(line)
            ?: throw IllegalArgumentException("第 $headlineLineIndex 行不是有效的 org 标题行：$line")

        val stars = match.groupValues[1]
        val content = match.groupValues.getOrElse(2) { "" }

        // 剥离标题内容中最前的已有 TODO 关键字（若命中关键字集合）。
        var rest = content
        val firstToken = rest.takeWhile { !it.isWhitespace() }
        if (firstToken.isNotEmpty() && firstToken in TODO_KEYWORDS) {
            rest = rest.substring(firstToken.length).trimStart()
        }

        lines[headlineLineIndex] = when {
            newState == null -> if (rest.isEmpty()) stars else "$stars $rest"
            rest.isEmpty() -> "$stars $newState"
            else -> "$stars $newState $rest"
        }
        return lines.joinToString("\n")
    }
}
