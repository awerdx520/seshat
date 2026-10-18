package com.seshat.app.gtd

/**
 * 条目展示的公共格式化逻辑（TODO 状态徽标配色、标签文本、正文摘要）。
 *
 * 抽出的原因：[GtdEntryAdapter] 与 `NotesListAdapter` 都需要一致的徽标配色与标签写法，
 * 集中在此处避免颜色表出现两份副本（改色只需改一处）。
 *
 * 颜色以 ARGB 字面量表达（`0xAARRGGBB`，与 `android.graphics.Color.parseColor("#RRGGBB")` 等价），
 * 因此本对象**不依赖 Android 运行时**，可在纯 JVM 单元测试中直接使用（见 `OrgEntryDisplayTest`）。
 */
internal object OrgEntryDisplay {

    /** 进行中状态（TODO/NEXT/STARTED/WAITING/HOLD 等）徽标底色。 */
    val COLOR_ACTIVE: Int = 0xFF1565C0.toInt()

    /** 已完成状态徽标底色。 */
    val COLOR_DONE: Int = 0xFF2E7D32.toInt()

    /** 已取消状态徽标底色。 */
    val COLOR_CANCELLED: Int = 0xFF757575.toInt()

    private const val STATE_DONE = "DONE"
    private const val STATE_CANCELLED = "CANCELLED"

    /** 属性抽屉（property drawer）的起止行。 */
    private const val PROPERTIES_START = ":PROPERTIES:"
    private const val PROPERTIES_END = ":END:"

    /** planning 关键字（org 中位于标题下方的固定位置，不属于正文描述）。 */
    private val PLANNING_PREFIXES = listOf("DEADLINE:", "SCHEDULED:", "CLOSED:")

    /**
     * 按 TODO 状态返回徽标底色。
     *
     * @param state TODO 关键字；`null` 不会调用本函数（无状态时调用方直接隐藏徽标）。
     */
    fun badgeColor(state: String?): Int = when (state) {
        STATE_DONE -> COLOR_DONE
        STATE_CANCELLED -> COLOR_CANCELLED
        else -> COLOR_ACTIVE
    }

    /**
     * 标签列表 → org 风格标签文本（形如 `:a:b:`）；空列表返回 `null`，由调用方隐藏视图。
     */
    fun tagText(tags: List<String>): String? =
        if (tags.isEmpty()) null
        else tags.joinToString(separator = ":", prefix = ":", postfix = ":")

    /**
     * 正文摘要：取正文中第一个**非 planning 行、非属性块行**的非空行并 trim。
     *
     * 跳过规则（按行判断，忽略前导/尾随空白）：
     * 1. `DEADLINE:` / `SCHEDULED:` / `CLOSED:` 开头的 planning 行；
     * 2. `:PROPERTIES:` 到 `:END:` 之间（含两端）的属性抽屉行；
     * 3. 只由冒号包裹的属性行（形如 `:ID: xxx`、`:CREATED: [...]`，可能出现在抽屉之外）；
     * 4. 纯空白行。
     *
     * **为何跳过**：列表副行（`item_note_entry.xml` 的 summary）只承载「正文描述」，
     * 用于一眼看出这条笔记讲什么。planning 行是 org 的元数据（截止/计划/关闭时间），
     * 列表并未为其单独设置展示位，作为摘要显示会挤掉真正的正文描述（B4 真机验收现象：
     * 副行显示 `DEADLINE: <2026-10-20 Tue>` 而不是正文）；属性行同理（`ID`/`CREATED` 等无阅读价值）。
     * 摘要也不重复展示 planning —— 未来若需要日期展示，应新增独立行而非复用摘要。
     *
     * @return 摘要文本；全部行都被跳过（或正文为空）返回 `null`，由调用方隐藏摘要行。
     */
    fun summaryOf(body: String): String? {
        var inProperties = false
        for (raw in body.lineSequence()) {
            // 先 trim，一并去掉 CRLF 的 \r
            val line = raw.trim()
            if (inProperties) {
                if (line.equals(PROPERTIES_END, ignoreCase = true)) inProperties = false
                continue
            }
            if (line.equals(PROPERTIES_START, ignoreCase = true)) {
                inProperties = true
                continue
            }
            if (line.isEmpty() || isPlanningLine(line) || isDrawerLine(line)) continue
            return line
        }
        return null
    }

    /** 是否 planning 行（`DEADLINE:` / `SCHEDULED:` / `CLOSED:` 开头，忽略大小写）。 */
    private fun isPlanningLine(line: String): Boolean =
        PLANNING_PREFIXES.any { line.startsWith(it, ignoreCase = true) }

    /**
     * 是否属性行：以 `:` 开头且首段冒号对之间有关键字（形如 `:ID: value`）。
     *
     * 只要求「第二个冒号紧跟在非空关键字之后」，因此 `:END:` 这类孤立属性行也会被跳过。
     */
    private fun isDrawerLine(line: String): Boolean {
        if (!line.startsWith(":") || line.length < 3) return false
        val close = line.indexOf(':', 1)
        return close > 1
    }
}
