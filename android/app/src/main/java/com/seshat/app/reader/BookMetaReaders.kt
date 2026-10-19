package com.seshat.app.reader

import android.content.Context
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import com.seshat.app.importer.BookImporter
import java.io.File

/**
 * 生产用 epub 元数据读取：整包读入内存 → [EpubParser] 解析 → 取标题/作者/章节数/封面。
 *
 * `progressKey` 用 [documentIdOf]（内容 SHA-256 前 32 hex），与 [EpubReaderActivity] 在无 uid 时的
 * 键选择一致（见该 Activity 的 `effectiveKey = uid ?: docId`）。
 */
class EpubBookMetaReader : BookMetaReader {
    override fun read(file: File): BookMeta? = try {
        val bytes = file.readBytes()
        val book = EpubParser.parse(ByteArrayEpubSource(bytes))
        BookMeta(
            title = book.title.ifBlank { file.nameWithoutExtension },
            author = book.author,
            totalCount = book.chapters.size,
            progressKey = documentIdOf(bytes),
            coverHref = book.coverHref,
        )
    } catch (_: Exception) {
        // 损坏 / 非 epub / 加密：书架跳过该文件而非整体失败
        null
    }
}

/**
 * 生产用 PDF 元数据读取：只开 [PdfRenderer] 取页数，不渲染任何页面（书架封面由 B3-T2 缓存层负责）。
 *
 * `progressKey` 用 `file://` uri 字符串，与 [PdfReaderActivity] 在无 uid 时的键选择一致。
 */
class PdfBookMetaReader : BookMetaReader {
    override fun read(file: File): BookMeta? {
        // PdfRenderer 未保证实现 Closeable（依赖 API 级别），故用 try/finally 显式关闭
        var pfd: ParcelFileDescriptor? = null
        var renderer: PdfRenderer? = null
        return try {
            pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
            renderer = PdfRenderer(pfd)
            BookMeta(
                title = file.nameWithoutExtension,
                author = null,
                totalCount = renderer.pageCount,
                progressKey = Uri.fromFile(file).toString(),
                coverHref = null,
            )
        } catch (_: Exception) {
            // 加密 / 损坏 / 非 PDF：跳过
            null
        } finally {
            runCatching { renderer?.close() }
            runCatching { pfd?.close() }
        }
    }
}

/** 按扩展名分派到 [EpubBookMetaReader] / [PdfBookMetaReader]（生产用默认实现）。 */
class DefaultBookMetaReader(
    private val epub: BookMetaReader = EpubBookMetaReader(),
    private val pdf: BookMetaReader = PdfBookMetaReader(),
) : BookMetaReader {
    override fun read(file: File): BookMeta? =
        if (file.extension.equals("pdf", ignoreCase = true)) pdf.read(file) else epub.read(file)
}

/**
 * 装配生产用 [BookLibrary]（供书架 UI 调用；[BookLibrary.load] 本身阻塞，调用方须放后台线程）。
 *
 * 两个进度 Store 的构造方式照抄各阅读器 Activity，保证读写同一份 prefs：
 * - epub：[ReadingProgressStore] + `reading_progress`
 * - pdf：[PdfProgressStore] + `pdf_reader`（与批注/手写共用文件，靠 `pdf_progress_` 前缀隔离）
 *
 * @param remote 远端清单来源（M9.2 B 批）：`null` 表示纯本地书架。传入的 lambda 在
 *               [BookLibrary.load] 内部（后台线程）才被调用，可安全读 [com.seshat.app.sync.ResourceIndex]
 *               或触发一次根清单拉取。
 */
fun openBookLibrary(
    context: Context,
    remote: (() -> List<RemoteBook>)? = null,
): BookLibrary {
    val epubStore = ReadingProgressStore(context)
    val pdfPrefs = context.getSharedPreferences(PdfReaderActivity.PREFS_NAME, Context.MODE_PRIVATE)
    val pdfStore = PdfProgressStore(
        read = { pdfPrefs.getString(it, null) },
        write = { key, value -> pdfPrefs.edit().putString(key, value).apply() },
        keys = { pdfPrefs.all.keys },
        remove = { key -> pdfPrefs.edit().remove(key).apply() },
    )
    return BookLibrary(
        booksDir = BookImporter(context).booksDir(),
        metaReader = DefaultBookMetaReader(),
        epubProgress = { epubStore.all() },
        pdfProgress = { pdfStore.loadAll() },
        remoteBooks = remote,
    )
}
