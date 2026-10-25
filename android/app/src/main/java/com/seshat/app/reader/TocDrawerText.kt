package com.seshat.app.reader

/**
 * 目录抽屉（[TocDrawer]）里**会被用户读到的文案**的纯函数来源。
 *
 * 与 `TocRow` / `AnnotationGrouping` 同范式：把「显示什么字」从「怎么摆视图」里剥出来，
 * 让文案分支能在纯 JVM 单测里断言（[TocDrawer] 自身依赖 Android View，测不了）。
 *
 * 为什么要区分书签是否支持：EPUB 侧**没有任何书签入口**（调用方传 `bookmarks = emptyList()`），
 * 若仍渲染「阅读时点顶栏的书签图标可添加」，就是在指一个不存在的按钮（审计项 E9）。
 */
internal object TocDrawerText {

    /** 书签空态第一行（无论是否支持书签都会显示，否则空区域毫无解释）。 */
    const val EMPTY_BOOKMARK_TITLE = "尚无书签"

    /** 书签空态第二行：操作指引，**仅在支持书签时**显示。 */
    const val EMPTY_BOOKMARK_HINT = "阅读时点顶栏的书签图标可添加"

    /** 底部状态行两段（页码 + 书签数）之间的分隔符，保持既有「 · 」风格。 */
    const val STATUS_SEPARATOR = " · "

    /**
     * 书签空态的两行文案。
     *
     * @param bookmarksSupported 当前阅读器是否支持书签（PDF `true` / EPUB `false`）
     * @return `first` 恒为 [EMPTY_BOOKMARK_TITLE]；`second` 是操作指引，**不支持书签时为 `null`**
     *   （调用方据此只渲染一行，不指向不存在的入口）
     */
    fun emptyBookmarkLines(bookmarksSupported: Boolean): Pair<String, String?> =
        EMPTY_BOOKMARK_TITLE to if (bookmarksSupported) EMPTY_BOOKMARK_HINT else null
}
