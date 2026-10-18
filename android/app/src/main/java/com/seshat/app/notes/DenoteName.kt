package com.seshat.app.notes

/**
 * denote 风格文件名解析：`20240101T120000--标题__tag1_tag2.org`。
 *
 * 不匹配（无时间戳前缀、扩展名不支持、标题为空）返回 `null`，
 * 由调用方回退到「首个 heading / 文件名」。纯函数，不依赖 Android 框架。
 */
internal object DenoteName {

    /**
     * 解析结果。
     *
     * @property title 标题（`--` 之后、首个 `__` 之前，保持原样）。
     * @property tags 标签（`__` 之后按 `_` 分割并过滤空串）。
     */
    data class ParsedName(val title: String, val tags: List<String>)

    /**
     * 只校验「时间戳前缀 + 扩展名」，标题/标签交给字符串切分处理。
     *
     * 不复用计划里的单条正则，是因为懒量词会让 `--__a.org` 的标题被解析成 `__a`
     * 而非空，无法满足「标题为空 → 返回 null」的约定。
     */
    private val NAME_REGEX = Regex("""^(\d{8}T\d{6})--(.+)\.(org|md)$""", RegexOption.IGNORE_CASE)

    /** 标签段分隔符。 */
    private const val TAG_SEPARATOR = "__"

    /** 解析文件名（不含路径）。 */
    fun parse(fileName: String): ParsedName? {
        val match = NAME_REGEX.matchEntire(fileName) ?: return null
        // groupValues[2] 是去掉时间戳前缀与扩展名后的部分，形如「标题__tag1_tag2」
        val stem = match.groupValues[2]
        val separatorIndex = stem.indexOf(TAG_SEPARATOR)
        val title = if (separatorIndex >= 0) stem.substring(0, separatorIndex) else stem
        // 标题为空（如 `20240101T120000--__a.org`）→ 交给调用方回退
        if (title.isBlank()) return null
        val tags = if (separatorIndex >= 0) {
            stem.substring(separatorIndex + TAG_SEPARATOR.length)
                .split('_')
                .filter { it.isNotEmpty() }
        } else {
            emptyList()
        }
        return ParsedName(title = title, tags = tags)
    }
}
