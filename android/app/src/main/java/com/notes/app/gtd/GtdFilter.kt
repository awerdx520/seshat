package com.notes.app.gtd

/**
 * GTD 视图的多条件过滤器（纯 JVM 逻辑，不依赖 Android 框架）。
 *
 * 对 [OrgEntry] 列表按「TODO 状态 + 优先级 + 标签」做组合过滤；
 * 任一维度取 `null` 表示该维度不过滤（即「全部」）。三个维度之间为「与」关系。
 */
object GtdFilter {

    /**
     * 组合过滤 [entries]，保持原有顺序。
     *
     * @param entries   待过滤条目。
     * @param todoState TODO 状态精确匹配（大小写敏感）；`null` = 全部状态。
     * @param priority  优先级字符匹配（忽略大小写）；`null` = 全部优先级。
     * @param tag       标签包含匹配（大小写敏感）；`null` = 全部标签。
     * @return 同时满足所有非空条件的条目。
     */
    fun filter(
        entries: List<OrgEntry>,
        todoState: String? = null,
        priority: Char? = null,
        tag: String? = null,
    ): List<OrgEntry> = entries.filter { entry ->
        (todoState == null || entry.todoState == todoState) &&
            (priority == null || entry.priority?.equals(priority, ignoreCase = true) == true) &&
            (tag == null || entry.tags.contains(tag))
    }
}
