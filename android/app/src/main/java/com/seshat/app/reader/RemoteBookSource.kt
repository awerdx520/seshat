package com.seshat.app.reader

import com.seshat.app.sync.ResourceEntry
import com.seshat.app.sync.ResourceIndex
import java.io.File

/**
 * 远端清单里的一本书（尚未落盘）。
 *
 * 由 [RemoteBookSource.fromIndex] 从 [ResourceIndex] 的条目派生：只保留「可阅读」的
 * `epub`/`pdf` 存活条目，并把 `path` 的末段抽成 [name]（书架目录里预期的文件名）。
 *
 * @property uid   资源稳定标识（落盘后阅读器按它同步进度）。
 * @property root  资源所属根。
 * @property path  根内相对路径（远端定位键）。
 * @property name  [path] 的文件名部分，即本地 `booksDir` 下的预期文件名。
 * @property size  远端字节数；`<= 0` 表示元数据未回填。
 * @property mtime 远端修改时间（毫秒），用于排序与占位条目的导入时间。
 */
data class RemoteBook(
    val uid: String,
    val root: String,
    val path: String,
    val name: String,
    val size: Long,
    val mtime: Long,
)

/** 远端清单 → 书架候选的纯逻辑（无网络、无 Android 依赖）。 */
internal object RemoteBookSource {

    /** 书架可读的扩展名（比较时忽略大小写）。 */
    private val SUPPORTED_EXTENSIONS = setOf("epub", "pdf")

    /**
     * 取 [root] 下扩展名为 `epub`/`pdf` 的**存活**（非墓碑）条目，按 [RemoteBook.mtime] 降序。
     *
     * 用于「书架上还没下载的书」：调用方再用 [localFileOf] 判断哪些其实已经落盘。
     */
    fun fromIndex(index: ResourceIndex, root: String): List<RemoteBook> =
        index.entriesInRoot(root)
            .filterNot { it.deleted }
            .mapNotNull { bookOf(it) }
            .sortedByDescending { it.mtime }

    /**
     * 本地是否已有同名且长度匹配的文件；有则返回该文件，否则 `null`。
     *
     * 判定为**文件存在** + （[RemoteBook.size] > 0 时）`length() == size`；
     * `size <= 0`（元数据未回填，见 `/api/changes` 不返回 size）时只判存在、不校验长度，
     * 避免把已下载的书误判成「未下载」。
     */
    fun localFileOf(booksDir: File, book: RemoteBook): File? {
        val file = File(booksDir, book.name)
        if (!file.isFile) return null
        if (book.size > 0 && file.length() != book.size) return null
        return file
    }

    /** 单个条目 → [RemoteBook]；扩展名不受支持时返回 `null`。 */
    private fun bookOf(entry: ResourceEntry): RemoteBook? {
        val name = entry.path.substringAfterLast('/')
        if (name.isEmpty()) return null
        val extension = name.substringAfterLast('.', "").lowercase()
        if (extension !in SUPPORTED_EXTENSIONS) return null
        return RemoteBook(
            uid = entry.uid,
            root = entry.root,
            path = entry.path,
            name = name,
            size = entry.size,
            mtime = entry.mtime,
        )
    }
}
