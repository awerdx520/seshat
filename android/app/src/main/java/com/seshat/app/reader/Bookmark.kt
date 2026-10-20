package com.seshat.app.reader

import kotlinx.serialization.Serializable

/**
 * PDF 书签（M10.10）。
 *
 * @property page 0-based 页索引
 * @property title 书签显示名；添加时取该页所在目录项标题，取不到则为「第 N 页」
 * @property createdAt 创建时间（毫秒），列表按它倒序
 */
@Serializable
data class PdfBookmark(
    val page: Int,
    val title: String,
    val createdAt: Long,
)

/**
 * 书签集合的纯函数操作（无 Android 依赖，可纯 JVM 单测）。
 *
 * 所有函数都返回**新列表**，不修改入参；同一页只允许一个书签。
 */
internal object Bookmarks {

    /**
     * 加入书签：同页已存在则不重复添加（返回原列表 + `added=false`）。
     *
     * 返回值保持「按页升序」——书签列表按阅读顺序排更符合目录习惯。
     *
     * @return 新列表与是否真正新增。
     */
    fun add(items: List<PdfBookmark>, bookmark: PdfBookmark): Pair<List<PdfBookmark>, Boolean> =
        if (items.any { it.page == bookmark.page }) {
            items to false
        } else {
            (items + bookmark).sortedBy { it.page } to true
        }

    /** 移除指定页的书签（该页无书签时原样返回等值新列表）。 */
    fun remove(items: List<PdfBookmark>, page: Int): List<PdfBookmark> =
        items.filterNot { it.page == page }

    /** 是否已有该页书签。 */
    fun has(items: List<PdfBookmark>, page: Int): Boolean = items.any { it.page == page }

    /** 按页升序排序（稳定，同页不可能出现多条）。 */
    fun sorted(items: List<PdfBookmark>): List<PdfBookmark> = items.sortedBy { it.page }
}
