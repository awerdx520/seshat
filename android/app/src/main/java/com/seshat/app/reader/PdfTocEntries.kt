package com.seshat.app.reader

/**
 * PDF 目录条目构造与当前项定位（纯函数，无 Android 依赖）。
 *
 * 对话框只认「标题 + 页码 + 缩进」三元组，故把 outline 树 → 条目的转换、以及
 * 「当前页对应哪一项」的定位都抽到这里，便于纯 JVM 单测。
 */
internal object PdfTocEntries {

    /** 对话框一行。 */
    data class Entry(val title: String, val pageIndex: Int, val depth: Int)

    /**
     * 构造目录条目：有 outline 用 outline，否则回退页码目录。
     *
     * @param outline [PdfOutlineReader.read] 的结果
     * @param pageCount 总页数（页码目录回退时使用）
     */
    fun build(
        outline: List<PdfOutlineReader.PdfOutlineItem>,
        pageCount: Int,
    ): List<Entry> = if (outline.isNotEmpty()) {
        // 有书签：先序拍平，depth 直接来自树层级（对话框按 depth 做缩进）
        PdfOutlineReader.flatten(outline).map { Entry(it.title, it.pageIndex, it.depth) }
    } else {
        // 无书签/解析失败：回退「第 N 页」页码目录（pageDirectory 已处理 pageCount <= 0）
        PdfOutlineReader.pageDirectory(pageCount).map { Entry(it.title, it.pageIndex, it.depth) }
    }

    /**
     * 当前页对应的目录项索引（用于对话框高亮）。
     *
     * 取「页码 <= currentPage 的**最后一项**」——目录项通常指向章节起始页，读者在某章中间
     * 翻阅时高亮的应是该章而不是下一章。表里没有合适项（全部在 currentPage 之后）返回 0；
     * 空表返回 -1（调用方不回传 initialSelection）。
     *
     * 页码为 [PdfOutlineReader.UNKNOWN_PAGE_INDEX]（-1，非页目标书签）的项永不匹配，
     * 因区间下界是 0。
     */
    fun indexForPage(entries: List<Entry>, currentPage: Int): Int {
        if (entries.isEmpty()) return -1
        val hit = entries.indexOfLast { it.pageIndex in 0..currentPage }
        return if (hit < 0) 0 else hit
    }
}
