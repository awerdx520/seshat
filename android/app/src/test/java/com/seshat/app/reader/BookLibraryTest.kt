package com.seshat.app.reader

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * 书架扫描单测：用 [TemporaryFolder] 造真实目录，用假 [BookMetaReader] 隔离 IO/解析。
 *
 * 生产实现的 `EpubBookMetaReader` 只依赖 JDK（zip + JAXP），故可一并做真解析验证。
 */
class BookLibraryTest {

    @get:Rule
    val tmp = TemporaryFolder()

    /** 每例自行创建的子目录（[TemporaryFolder] 在测试实例构造后才创建，故不能在此处取 root）。 */
    private lateinit var books: File

    /** 默认假 reader：epub 给 10 章、pdf 给 12 页；用文件名当标题，用途可读。 */
    private val fakeMeta = BookMetaReader { file ->
        when (file.extension.lowercase()) {
            "epub" -> BookMeta(
                title = file.nameWithoutExtension,
                author = "作者",
                totalCount = 10,
                progressKey = "key-${file.nameWithoutExtension}",
                coverHref = "cover.jpg",
            )

            "pdf" -> BookMeta(
                title = file.nameWithoutExtension,
                author = null,
                totalCount = 12,
                progressKey = "file://${file.absolutePath}",
                coverHref = null,
            )

            else -> null
        }
    }

    private fun library(
        metaReader: BookMetaReader = fakeMeta,
        epubProgress: Map<String, ReadingProgress> = emptyMap(),
        pdfProgress: Map<String, PdfProgress> = emptyMap(),
        remoteBooks: (() -> List<RemoteBook>)? = null,
    ): BookLibrary = BookLibrary(
        booksDir = books,
        metaReader = metaReader,
        epubProgress = { epubProgress },
        pdfProgress = { pdfProgress },
        remoteBooks = remoteBooks,
    )

    /** 造远端清单条目（name 一般与 path 末段一致）。 */
    private fun remote(
        name: String,
        uid: String = "uid-$name",
        path: String = "lib/$name",
        size: Long = 100,
        mtime: Long = 5_000,
    ) = RemoteBook(uid = uid, root = "main", path = path, name = name, size = size, mtime = mtime)

    @Test
    fun emptyDirReturnsEmptyList() {
        val dir = tmp.newFolder("books-empty")

        val result = BookLibrary(dir, fakeMeta, { emptyMap() }, { emptyMap() }).load()

        assertTrue(result.isEmpty())
    }

    @Test
    fun missingDirReturnsEmptyListInsteadOfThrowing() {
        val dir = File(tmp.root, "not-exists")

        val result = BookLibrary(dir, fakeMeta, { emptyMap() }, { emptyMap() }).load()

        assertTrue(result.isEmpty())
    }

    @Test
    fun scansEpubAndPdfWithCorrectTypes() {
        books = tmp.newFolder("books")
        File(books, "a.epub").writeText("x")
        File(books, "b.epub").writeText("x")
        File(books, "c.pdf").writeText("x")

        val result = library().load()

        assertEquals(3, result.size)
        assertEquals(
            mapOf("a" to BookType.EPUB, "b" to BookType.EPUB, "c" to BookType.PDF),
            result.associate { it.title to it.type },
        )
    }

    @Test
    fun ignoresUnsupportedExtensions() {
        books = tmp.newFolder("books-mixed")
        File(books, "book.epub").writeText("x")
        File(books, "notes.txt").writeText("x")
        File(books, "todo.org").writeText("x")

        val result = library().load()

        assertEquals(listOf("book"), result.map { it.title })
    }

    @Test
    fun skipsFilesWhoseMetaReadFails() {
        books = tmp.newFolder("books-broken")
        File(books, "good.epub").writeText("x")
        File(books, "broken.epub").writeText("x")

        val failing = BookMetaReader { file ->
            if (file.nameWithoutExtension == "broken") null else fakeMeta.read(file)
        }

        val result = library(metaReader = failing).load()

        assertEquals(listOf("good"), result.map { it.title })
    }

    @Test
    fun epubProgressMapsChapterIndexToPercent() {
        books = tmp.newFolder("books-progress")
        File(books, "book.epub").writeText("x")

        val result = library(
            epubProgress = mapOf(
                "key-book" to ReadingProgress(documentId = "key-book", chapterIndex = 5, updatedAt = 777L),
            ),
        ).load()

        val item = result.single()
        assertEquals(50, item.percent) // 5/10 章
        assertEquals(777L, item.lastReadAt)
    }

    @Test
    fun pdfProgressMapsPageToPercent() {
        books = tmp.newFolder("books-pdf")
        val pdf = File(books, "doc.pdf").apply { writeText("x") }

        val result = library(
            pdfProgress = mapOf("file://${pdf.absolutePath}" to PdfProgress(page = 3, updatedAt = 555L)),
        ).load()

        val item = result.single()
        assertEquals(25, item.percent) // 3/12 页
        assertEquals(555L, item.lastReadAt)
    }

    @Test
    fun filterReturnsMatchingSubset() {
        books = tmp.newFolder("books-filter")
        File(books, "unread.epub").writeText("x")
        File(books, "reading.epub").writeText("x")
        File(books, "finished.epub").writeText("x")

        val lib = library(
            epubProgress = mapOf(
                "key-reading" to ReadingProgress(documentId = "key-reading", chapterIndex = 4),
                "key-finished" to ReadingProgress(documentId = "key-finished", chapterIndex = 10),
            ),
        )

        assertEquals(listOf("unread"), lib.load(filter = BookFilter.UNREAD).map { it.title })
        assertEquals(listOf("reading"), lib.load(filter = BookFilter.READING).map { it.title })
        assertEquals(listOf("finished"), lib.load(filter = BookFilter.FINISHED).map { it.title })
        assertEquals(3, lib.load(filter = BookFilter.ALL).size)
    }

    @Test
    fun recentSortOrdersByLastReadAt() {
        books = tmp.newFolder("books-sort")
        File(books, "old.epub").writeText("x")
        File(books, "new.epub").writeText("x")

        val result = library(
            epubProgress = mapOf(
                "key-old" to ReadingProgress(documentId = "key-old", chapterIndex = 1, updatedAt = 100L),
                "key-new" to ReadingProgress(documentId = "key-new", chapterIndex = 2, updatedAt = 900L),
            ),
        ).load(sort = BookSort.RECENT)

        assertEquals(listOf("new", "old"), result.map { it.title })
    }

    @Test
    fun importedAtComesFromFileLastModified() {
        books = tmp.newFolder("books-mtime")
        val file = File(books, "book.epub").apply { writeText("x") }
        file.setLastModified(1_234_567_890_000L)

        val item = library().load().single()

        assertEquals(1_234_567_890_000L, item.importedAt)
    }

    // ---- 远端清单合并（M9.2 B） ----

    @Test
    fun remoteOnlyBooksAppearAsPlaceholdersNotDownloaded() {
        books = tmp.newFolder("books-remote-only")
        val a = remote("a.epub", uid = "u-a", mtime = 9_000)
        val b = remote("b.pdf", uid = "u-b", mtime = 8_000)

        val result = library(remoteBooks = { listOf(a, b) }).load()

        assertEquals(listOf("u-a", "u-b"), result.map { it.uid })
        val epub = result.first { it.uid == "u-a" }
        assertFalse(epub.isDownloaded)
        assertEquals(a, epub.remote)
        assertEquals(File(books, "a.epub"), epub.file)
        assertEquals(BookType.EPUB, epub.type)
        assertEquals("a", epub.title)
        assertNull(epub.author)
        assertEquals(0, epub.totalCount)
        assertEquals("lib/a.epub", epub.progressKey)
        assertEquals(0, epub.percent)
        assertEquals(0L, epub.lastReadAt)
        assertEquals(9_000L, epub.importedAt)
        assertEquals(BookType.PDF, result.first { it.uid == "u-b" }.type)
        // 未下载条目 percent=0 → 出现在「未读」过滤里
        assertEquals(2, library(remoteBooks = { listOf(a, b) }).load(filter = BookFilter.UNREAD).size)
    }

    @Test
    fun downloadedRemoteBookKeepsLocalMetaAndGetsUid() {
        books = tmp.newFolder("books-remote-downloaded")
        File(books, "a.epub").writeBytes(ByteArray(100)) // 长度与远端 size 一致 → 判定已落盘
        val a = remote("a.epub", uid = "u-a", size = 100, mtime = 9_000)

        val item = library(remoteBooks = { listOf(a) }).load().single()

        assertTrue(item.isDownloaded)
        assertEquals("u-a", item.uid)
        assertEquals(a, item.remote)
        // 已落盘时用本地真实元数据（作者/章节数/进度键），不用占位值
        assertEquals("作者", item.author)
        assertEquals(10, item.totalCount)
        assertEquals("key-a", item.progressKey)
    }

    @Test
    fun nullRemoteBooksBehavesLikePureLocal() {
        books = tmp.newFolder("books-no-remote")
        File(books, "a.epub").writeText("x")

        val item = library().load().single()

        assertNull(item.remote)
        assertNull(item.uid)
        assertTrue(item.isDownloaded)
    }

    @Test
    fun sameNameButDifferentLengthKeepsLocalEntryOnly() {
        books = tmp.newFolder("books-same-name-diff-size")
        File(books, "a.epub").writeBytes(ByteArray(100)) // 本地 100 字节
        val a = remote("a.epub", uid = "u-a", size = 200, mtime = 9_000) // 远端 200 字节

        val result = library(remoteBooks = { listOf(a) }).load()

        // 设计 §4：只有「本地无同名文件」的远端条目才追加占位——同名但长度不同意味着远端版本
        // 有新内容，仍只显示本地那一本（避免书架出现两本同名书），差异由下载流程覆盖。
        val item = result.single()
        assertTrue(item.isDownloaded)
        assertEquals("u-a", item.uid)
        assertEquals(a, item.remote)
        assertEquals(100L, item.file.length())
    }

    // ---- 生产实现 EpubBookMetaReader（纯 JDK 解析，可真跑） ----

    @Test
    fun epubMetaReaderExtractsTitleChaptersAndContentHashKey() {
        books = tmp.newFolder("books-real-epub")
        val bytes = epubBytes(title = "真书", chapterCount = 3)
        val file = File(books, "real.epub").apply { writeBytes(bytes) }

        val meta = EpubBookMetaReader().read(file)!!

        assertEquals("真书", meta.title)
        assertEquals(3, meta.totalCount)
        // 关键不变量：progressKey 必须与阅读器一致（内容 SHA-256 前 32 hex）
        assertEquals(documentIdOf(bytes), meta.progressKey)
        assertNull(meta.coverHref)
        assertNull(meta.author)
    }

    @Test
    fun epubMetaReaderReturnsNullForCorruptFile() {
        books = tmp.newFolder("books-corrupt")
        val file = File(books, "broken.epub").apply { writeText("not a zip") }

        assertNull(EpubBookMetaReader().read(file))
    }

    @Test
    fun epubLibraryComputesProgressViaRealContentHash() {
        books = tmp.newFolder("books-real-progress")
        val bytes = epubBytes(title = "真书", chapterCount = 4)
        File(books, "real.epub").writeBytes(bytes)

        val result = BookLibrary(
            booksDir = books,
            metaReader = EpubBookMetaReader(),
            epubProgress = {
                mapOf(documentIdOf(bytes) to ReadingProgress(documentId = documentIdOf(bytes), chapterIndex = 2, updatedAt = 42L))
            },
            pdfProgress = { emptyMap() },
        ).load()

        val item = result.single()
        assertEquals(50, item.percent) // 2/4 章
        assertEquals(42L, item.lastReadAt)
    }

    /** 造最小可解析 epub（container → opf → N 章 spine）。 */
    private fun epubBytes(title: String, chapterCount: Int): ByteArray {
        val items = (1..chapterCount).joinToString("") { i ->
            """<item id="c$i" href="c$i.xhtml" media-type="application/xhtml+xml"/>"""
        }
        val spines = (1..chapterCount).joinToString("") { i -> """<itemref idref="c$i"/>""" }
        return zipBytes(
            "META-INF/container.xml" to """<?xml version="1.0" encoding="UTF-8"?>
                <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
                  <rootfiles>
                    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
                  </rootfiles>
                </container>
            """.trimIndent(),
            "content.opf" to """<?xml version="1.0" encoding="UTF-8"?>
                <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">
                  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
                    <dc:identifier id="id">urn:uuid:test</dc:identifier>
                    <dc:title>$title</dc:title>
                    <dc:language>zh</dc:language>
                  </metadata>
                  <manifest>$items</manifest>
                  <spine>$spines</spine>
                </package>
            """.trimIndent(),
        )
    }

    private fun zipBytes(vararg entries: Pair<String, String>): ByteArray {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            entries.forEach { (name, content) ->
                zip.putNextEntry(ZipEntry(name))
                zip.write(content.toByteArray(Charsets.UTF_8))
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }
}
