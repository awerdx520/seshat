package com.seshat.app.reader

import java.io.File
import kotlinx.serialization.Serializable

/** 书籍类型（书架层只需要「可阅读」的两种）。 */
enum class BookType {
    /** EPUB 电子书。 */
    EPUB,

    /** PDF 文档。 */
    PDF,
}

/**
 * 单本元数据（由 [BookMetaReader] 提取，便于测试注入假实现）。
 *
 * @property title       展示标题。
 * @property author      作者；未知为 `null`（PDF 恒为 `null`）。
 * @property totalCount  总量：epub 为章节数，pdf 为页数。用于换算进度百分比。
 * @property progressKey 进度存储键：epub 为内容哈希（[documentIdOf]），pdf 为 `file://` uri 字符串。
 *                       必须与阅读器端「无 uid」时的键保持一致，否则书架查不到进度。
 * @property coverHref   封面相对 opfDir 的路径（epub）；pdf 为 `null`。
 *
 * 标 [Serializable] 是为了能被 [CoverCache] 以 JSON 形式缓存到磁盘（见 [CachedBookMeta]）。
 */
@Serializable
data class BookMeta(
    val title: String,
    val author: String?,
    val totalCount: Int,
    val progressKey: String,
    val coverHref: String?,
)

/** 从文件提取元数据；实现方负责 IO（生产实现会在后台线程被调用）。 */
fun interface BookMetaReader {
    fun read(file: File): BookMeta?
}

/**
 * 书架条目。
 *
 * @property file        库内文件（`filesDir/books/` 下的普通文件）。
 * @property type        书籍类型。
 * @property title       展示标题。
 * @property author      作者；未知为 `null`。
 * @property totalCount  章节数 / 页数。
 * @property progressKey 进度存储键（见 [BookMeta.progressKey]）。
 * @property percent     已读百分比（0..100）。
 * @property lastReadAt  最近阅读时间（进度 `updatedAt`）；无进度为 0。
 * @property importedAt  导入时间（取 `file.lastModified()`）。
 */
data class BookItem(
    val file: File,
    val type: BookType,
    val title: String,
    val author: String?,
    val totalCount: Int,
    val progressKey: String,
    val percent: Int,
    val lastReadAt: Long,
    val importedAt: Long,
)

/**
 * 本地书架：扫描书籍目录 → 提取元数据 → 合并进度 → 过滤 → 排序。
 *
 * 进度通过函数注入（而非直接持有 Store），使本类可在 JVM 单测中用内存 map 覆盖全部逻辑；
 * 生产装配见 [openBookLibrary]。
 *
 * @param booksDir     书籍目录（生产为 `filesDir/books/`）；不存在时视为空书架。
 * @param metaReader   文件 → 元数据（返回 `null` 的文件被跳过：损坏/不支持）。
 * @param epubProgress 取全部 epub 进度（键 = 有效键）。
 * @param pdfProgress  取全部 PDF 进度（键 = 剥掉前缀后的 docId）。
 */
class BookLibrary(
    private val booksDir: File,
    private val metaReader: BookMetaReader,
    private val epubProgress: () -> Map<String, ReadingProgress>,
    private val pdfProgress: () -> Map<String, PdfProgress>,
) {
    /**
     * 扫描并装配书架列表。**IO 阻塞**，调用方负责放到后台线程。
     *
     * 只收 `epub` / `pdf`（扩展名忽略大小写）的普通文件；解析失败的文件静默跳过。
     */
    fun load(
        filter: BookFilter = BookFilter.ALL,
        sort: BookSort = BookSort.RECENT,
    ): List<BookItem> {
        val files = booksDir.listFiles() ?: return emptyList()
        // 进度表只取一次：遍历中反复调用会重复扫 prefs
        val epub = epubProgress()
        val pdf = pdfProgress()
        val items = ArrayList<BookItem>(files.size)
        for (file in files.sortedBy { it.name }) {
            if (!file.isFile) continue
            val type = typeOf(file) ?: continue
            val meta = metaReader.read(file) ?: continue
            val item = when (type) {
                BookType.EPUB -> {
                    val progress = epub[meta.progressKey]
                    buildItem(file, type, meta, progress?.chapterIndex ?: 0, progress?.updatedAt ?: 0L)
                }

                BookType.PDF -> {
                    val progress = pdf[meta.progressKey]
                    buildItem(file, type, meta, progress?.page ?: 0, progress?.updatedAt ?: 0L)
                }
            }
            if (BookShelfLogic.matches(filter, item.percent)) items += item
        }
        return BookShelfLogic.sort(sort, items)
    }

    private fun buildItem(
        file: File,
        type: BookType,
        meta: BookMeta,
        current: Int,
        updatedAt: Long,
    ): BookItem = BookItem(
        file = file,
        type = type,
        title = meta.title,
        author = meta.author,
        totalCount = meta.totalCount,
        progressKey = meta.progressKey,
        percent = BookShelfLogic.progressPercent(current, meta.totalCount),
        lastReadAt = updatedAt,
        importedAt = file.lastModified(),
    )

    /** 按扩展名判定类型；非 epub/pdf 返回 `null`。 */
    private fun typeOf(file: File): BookType? = when (file.extension.lowercase()) {
        "epub" -> BookType.EPUB
        "pdf" -> BookType.PDF
        else -> null
    }
}
