package com.notes.app.gtd

/**
 * 单条 org 条目（headline）及其正文。
 *
 * 对应 org-mode 中一个以 `*`（可多个）开头的标题行，及其下方直到下一个标题之前的正文。
 *
 * @property level 标题层级，等于开头星号的数量（`*` = 1，`**` = 2，……）。
 * @property title 剥离 TODO 关键字、优先级与标签后的纯标题文本（已 trim）。
 * @property todoState 识别到的 TODO 关键字（如 `TODO`、`DONE`）；无则为 `null`。
 * @property priority 优先级字符（统一大写，如 `A`）；无则为 `null`。
 * @property tags 标签列表（不含冒号），按出现顺序排列；无则为空列表。
 * @property scheduled `SCHEDULED: <...>` 中尖括号内的原文；无则为 `null`。
 * @property deadline `DEADLINE: <...>` 中尖括号内的原文；无则为 `null`。
 * @property body 归属于本条目、紧随其后的非标题行（保留原始内容，去掉首尾空行）。
 */
data class OrgEntry(
    val level: Int,
    val title: String,
    val todoState: String?,
    val priority: Char?,
    val tags: List<String>,
    val scheduled: String?,
    val deadline: String?,
    val body: String,
)

/**
 * 一份解析后的 org 文档。
 *
 * @property entries 按源码顺序排列的全部条目。
 */
data class OrgDocument(val entries: List<OrgEntry>) {

    /** 返回所有带 TODO 状态（[OrgEntry.todoState] 非 `null`）的条目。 */
    fun todoEntries(): List<OrgEntry> = entries.filter { it.todoState != null }

    /** 返回包含指定标签（大小写敏感）的条目。 */
    fun byTag(tag: String): List<OrgEntry> = entries.filter { it.tags.contains(tag) }

    /** 返回优先级等于 [priority] 的条目（忽略大小写）。 */
    fun byPriority(priority: Char): List<OrgEntry> =
        entries.filter { it.priority != null && it.priority.equals(priority, ignoreCase = true) }

    /** 返回 TODO 状态等于 [state] 的条目（大小写敏感）。 */
    fun byTodoState(state: String): List<OrgEntry> = entries.filter { it.todoState == state }
}

/**
 * org-mode 纯文本解析器（纯 JVM 逻辑，不依赖 Android 框架）。
 *
 * 将 org 文本解析为 [OrgDocument]（由若干 [OrgEntry] 组成），供 GTD（agenda / TODO 视图）使用。
 *
 * 解析规则（覆盖常见 org 方言）：
 * - **标题行**：匹配 `^\*+(\s+内容)?$`。星号数量即 [OrgEntry.level]；星号后必须跟空白或行尾，
 *   因此普通以 `*` 开头的强调文本（如 `**bold**`，星号后非空白）不会误判为标题。
 * - **非标题行**：归入其所属（上方最近）条目的 [OrgEntry.body]；首个标题之前的散落文本被忽略。
 * - **TODO 状态**：星号后最前的空白分隔 token 若命中 [todoKeywords] 即识别为状态，并从标题剥离。
 * - **优先级**：标题内 `[#A]`/`[#a]`（统一转为大写字符）；若标题内无，则回退读取正文
 *   `:PROPERTIES:` 块中的 `:PRIORITY: A`。
 * - **标签**：标题末尾形如 `:tag1:tag2:` 的连续冒号块，剥离为标签列表。
 * - **计划时间**：正文中 `SCHEDULED: <2026-10-11>` / `DEADLINE: <2026-10-15>`，取尖括号内原文
 *   （不含尖括号），保留为字符串不做日期解析。
 *
 * 标题内部处理顺序：先剥优先级 `[#X]` → 再剥末尾标签 `:...:` → 再剥最前的 TODO 关键字 →
 * 剩余文本 trim 后即 [OrgEntry.title]。
 *
 * @param todoKeywords 可配置的 TODO 关键字集合，默认 [DEFAULT_TODO_KEYWORDS]。
 */
class OrgParser(val todoKeywords: Set<String> = DEFAULT_TODO_KEYWORDS) {

    /**
     * 解析 org 文本。
     *
     * @param text org 源文本；空字符串返回不含任何条目的 [OrgDocument]。
     * @return 解析得到的 [OrgDocument]。
     */
    fun parse(text: String): OrgDocument {
        val entries = mutableListOf<OrgEntry>()
        var currentLevel: Int? = null
        var currentHeadline: String = ""
        var currentBody = mutableListOf<String>()

        // 把当前累积的条目落盘到结果列表。
        fun flush() {
            val level = currentLevel ?: return
            entries.add(buildEntry(level, currentHeadline, currentBody))
        }

        for (rawLine in text.lines()) {
            val match = HEADLINE_REGEX.matchEntire(rawLine)
            if (match != null) {
                flush()
                currentLevel = match.groupValues[1].length
                // 组 1 = 星号；组 2 = 标题内容（正则中的 (?:...) 不占组号）。
                currentHeadline = match.groupValues.getOrElse(2) { "" }
                currentBody = mutableListOf()
            } else if (currentLevel != null) {
                currentBody.add(rawLine)
            }
            // 首个标题前的散落文本：currentLevel 仍为 null，直接忽略。
        }
        flush()
        return OrgDocument(entries)
    }

    /** 把一个标题行 + 其正文组装为 [OrgEntry]。 */
    private fun buildEntry(level: Int, headline: String, bodyLines: List<String>): OrgEntry {
        var work = headline.trim()

        // 1) 优先级 [#X]（标题内）
        var priority: Char? = null
        PRIORITY_REGEX.find(work)?.let { m ->
            priority = m.groupValues[1].first().uppercaseChar()
            work = work.removeRange(m.range).trim()
        }

        // 2) 末尾标签 :tag1:tag2:
        var tags: List<String> = emptyList()
        TAGS_REGEX.find(work)?.let { m ->
            tags = m.groupValues[1].split(':').filter { it.isNotEmpty() }
            work = work.removeRange(m.range).trim()
        }

        // 3) 最前的 TODO 关键字
        var todo: String? = null
        val firstToken = work.takeWhile { !it.isWhitespace() }
        if (firstToken.isNotEmpty() && firstToken in todoKeywords) {
            todo = firstToken
            work = work.substring(firstToken.length).trim()
        }

        val title = work.trim()

        val bodyText = bodyLines.joinToString("\n").trim('\n')

        // 计划时间：取尖括号内原文
        val scheduled = SCHEDULED_REGEX.find(bodyText)?.groupValues?.get(1)
        val deadline = DEADLINE_REGEX.find(bodyText)?.groupValues?.get(1)

        // PROPERTIES 块优先级：仅当标题内未指定时回退
        if (priority == null) {
            priority = PROPERTIES_PRIORITY_REGEX
                .find(bodyText)?.groupValues?.get(1)?.firstOrNull()?.uppercaseChar()
        }

        return OrgEntry(
            level = level,
            title = title,
            todoState = todo,
            priority = priority,
            tags = tags,
            scheduled = scheduled,
            deadline = deadline,
            body = bodyText,
        )
    }

    companion object {
        /** 默认支持的 TODO 关键字集合。 */
        val DEFAULT_TODO_KEYWORDS: Set<String> =
            linkedSetOf("TODO", "NEXT", "STARTED", "WAITING", "HOLD", "DONE", "CANCELLED")

        /** 标题行：若干星号 + 可选（空白 + 内容）。 */
        private val HEADLINE_REGEX = Regex("""^(\*+)(?:\s+(.*))?$""")

        /** 标题内优先级 `[#A]`（含小写）。 */
        private val PRIORITY_REGEX = Regex("""\[#([A-Za-z0-9])\]""")

        /** 标题末尾连续标签块 `:a:b:`（前面需为空白或行首）。 */
        private val TAGS_REGEX =
            Regex("""(?:^|\s)(:[A-Za-z0-9_@#%]+(?::[A-Za-z0-9_@#%]+)*:)\s*$""")

        /** `SCHEDULED: <...>`，捕获尖括号内原文。 */
        private val SCHEDULED_REGEX = Regex("""SCHEDULED:\s*<([^>]*)>""")

        /** `DEADLINE: <...>`，捕获尖括号内原文。 */
        private val DEADLINE_REGEX = Regex("""DEADLINE:\s*<([^>]*)>""")

        /** PROPERTIES 块中的 `:PRIORITY: A`。 */
        private val PROPERTIES_PRIORITY_REGEX = Regex(""":PRIORITY:\s*([A-Za-z0-9])""")
    }
}
