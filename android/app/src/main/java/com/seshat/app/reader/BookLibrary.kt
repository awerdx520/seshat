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
 * @property importedAt  导入时间（取 `file.lastModified()`；远端未下载条目取远端 `mtime`）。
 * @property remote      远端来源；`null` = 纯本地书。
 * @property uid         服务端 uid（阅读器按它同步进度）；`null` = 无服务端身份。
 * @property isDownloaded 本地文件是否已就绪（远端清单里有、但尚未下载时为 `false`）。
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
    /** 远端来源（null = 纯本地书）。 */
    val remote: RemoteBook? = null,
    /** 服务端 uid（用于阅读器按 uid 同步）；null = 无服务端身份。 */
    val uid: String? = null,
    /** 本地文件是否已就绪（远端未下载时为 false）。 */
    val isDownloaded: Boolean = true,
)

/**
 * 本地书架：扫描书籍目录 → 提取元数据 → 合并进度 → 过滤 → 排序。
 *
 * 进度通过函数注入（而非直接持有 Store），使本类可在 JVM 单测中用内存 map 覆盖全部逻辑；
 * 生产装配见 [openBookLibrary]。
 *
 * 远端清单同样以函数注入（[remoteBooks]），避免本类依赖 `ResourceIndex`/网络：
 * 传 `null` 即为纯本地书架（与 M9.2 之前行为一致）。
 *
 * @param booksDir     书籍目录（生产为 `filesDir/books/`）；不存在时视为空书架。
 * @param metaReader   文件 → 元数据（返回 `null` 的文件被跳过：损坏/不支持）。
 * @param epubProgress 取全部 epub 进度（键 = 有效键）。
 * @param pdfProgress  取全部 PDF 进度（键 = 剥掉前缀后的 docId）。
 * @param remoteBooks  远端清单来源（`null` = 不用远端）：返回**扁平**的 [RemoteBook] 列表，
 *                     本类内部按 [RemoteBook.name] 建反查表（同名时取 `mtime` 最大者）。
 *                     之所以不用 `Map<root, List<RemoteBook>>`：书架只关心「有哪些书」，
 *                     root 只在取清单时用得到（见 [RemoteBookSource.fromIndex]）。
 */
class BookLibrary(
    private val booksDir: File,
    private val metaReader: BookMetaReader,
    private val epubProgress: () -> Map<String, ReadingProgress>,
    private val pdfProgress: () -> Map<String, PdfProgress>,
    private val remoteBooks: (() -> List<RemoteBook>)? = null,
) {
    /**
     * 扫描并装配书架列表。**IO 阻塞**，调用方负责放到后台线程。
     *
     * 只收 `epub` / `pdf`（扩展名忽略大小写）的普通文件；解析失败的文件静默跳过。
     *
     * 配置了 [remoteBooks] 时，本地扫描结果会与远端清单合并（按**文件名**对齐）：
     * - 本地已有同名文件 → 只保留本地条目（带真实元数据），并把 `uid` / `remote` 填上
     *   （阅读器据此按 uid 同步进度）；即使长度与远端不同也如此——远端版本更新时由下载流程
     *   覆盖本地文件，避免书架出现两本同名书；
     * - 本地**没有**同名文件（或该文件解析失败）→ 追加一个占位条目
     *   （`isDownloaded = false`、`percent = 0`、`file` 指向预期落点 `booksDir/<name>`）。
     */
    fun load(
        filter: BookFilter = BookFilter.ALL,
        sort: BookSort = BookSort.RECENT,
    ): List<BookItem> {
        val remotes = remoteBooks?.invoke()?.sortedByDescending { it.mtime } ?: emptyList()
        // 同名反查表：远端清单已按 mtime 降序，putIfAbsent 保留最新的一本
        val remoteByName = HashMap<String, RemoteBook>()
        for (book in remotes) remoteByName.putIfAbsent(book.name, book)

        // 进度表只取一次：遍历中反复调用会重复扫 prefs
        val epub = epubProgress()
        val pdf = pdfProgress()
        val files = booksDir.listFiles() ?: emptyArray()
        val items = ArrayList<BookItem>(files.size + remotes.size)
        // 本地已存在的文件名（含解析失败的）：远端占位不再重复出现
        val localNames = HashSet<String>(files.size)
        for (file in files.sortedBy { it.name }) {
            if (!file.isFile) continue
            localNames += file.name
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
            // 已落盘的本地书：反查同名远端条目，补上 uid / remote
            val remote = remoteByName[file.name]
            val merged = if (remote == null) item else item.copy(remote = remote, uid = remote.uid)
            if (BookShelfLogic.matches(filter, merged.percent)) items += merged
        }
        // 远端有、本地没有的书：追加占位条目
        for (book in remotes) {
            if (book.name in localNames) continue
            val type = typeOfName(book.name) ?: continue
            val placeholder = placeholderOf(book, type)
            if (BookShelfLogic.matches(filter, placeholder.percent)) items += placeholder
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

    /** 远端未下载条目的占位：无本地元数据可读，字段按约定填固定值。 */
    private fun placeholderOf(book: RemoteBook, type: BookType): BookItem = BookItem(
        file = File(booksDir, book.name),
        type = type,
        title = book.name.substringBeforeLast('.', book.name),
        author = null,
        totalCount = 0,
        progressKey = book.path,
        percent = 0,
        lastReadAt = 0,
        importedAt = book.mtime,
        remote = book,
        uid = book.uid,
        isDownloaded = false,
    )

    /** 按扩展名判定类型；非 epub/pdf 返回 `null`。 */
    private fun typeOf(file: File): BookType? = typeOfName(file.name)

    /** 按文件名判定类型（远端条目没有 [File] 对象可用）。 */
    private fun typeOfName(name: String): BookType? = when (name.substringAfterLast('.', "").lowercase()) {
        "epub" -> BookType.EPUB
        "pdf" -> BookType.PDF
        else -> null
    }
}
