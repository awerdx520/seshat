package com.seshat.app.reader

/** 书架过滤条件。 */
enum class BookFilter {
    /** 全部（不过滤）。 */
    ALL,

    /** 未读：进度 0%。 */
    UNREAD,

    /** 在读：进度 1%..99%。 */
    READING,

    /** 已读：进度 100%。 */
    FINISHED,
}

/** 书架排序方式。 */
enum class BookSort {
    /** 最近阅读优先（`lastReadAt` 降序，同值按标题）。 */
    RECENT,

    /** 书名升序（忽略大小写）。 */
    TITLE,

    /** 导入时间倒序（最近导入在前）。 */
    IMPORT_TIME,
}

/**
 * 书架纯逻辑：进度百分比换算、过滤判定、排序。
 *
 * 刻意不含任何 Android / IO 依赖，便于 JVM 单测直接覆盖全部边界。
 */
internal object BookShelfLogic {

    /**
     * 把「当前进度 / 总量」换算成 0..100 的整数百分比。
     *
     * 边界：`total <= 0`（如未解析出章节/页数）或 `current <= 0`（未开始）一律 0；
     * 超过总量（数据漂移，如书籍重新解析后章节变少）夹紧到 100；向下取整（1/3 → 33）。
     */
    fun progressPercent(current: Int, total: Int): Int {
        if (total <= 0 || current <= 0) return 0
        // 用 Long 计算避免 current * 100 溢出
        return (current.toLong() * 100 / total).toInt().coerceIn(0, 100)
    }

    /** 过滤判定：读进度百分比是否满足 [filter]。 */
    fun matches(filter: BookFilter, percent: Int): Boolean = when (filter) {
        BookFilter.ALL -> true
        BookFilter.UNREAD -> percent == 0
        BookFilter.READING -> percent in 1..99
        BookFilter.FINISHED -> percent >= 100
    }

    /** 排序（返回新表，不修改 [items] 的顺序）。 */
    fun sort(sort: BookSort, items: List<BookItem>): List<BookItem> = when (sort) {
        // 最近阅读：无进度者为 0，自然沉底
        BookSort.RECENT -> items.sortedWith(
            compareByDescending<BookItem> { it.lastReadAt }.thenBy { it.title },
        )

        // 书名：忽略大小写（中文按码点原序）
        BookSort.TITLE -> items.sortedWith(
            compareBy(String.CASE_INSENSITIVE_ORDER) { it.title },
        )

        BookSort.IMPORT_TIME -> items.sortedByDescending { it.importedAt }
    }
}
