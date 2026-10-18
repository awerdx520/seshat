package com.seshat.app.reader

import java.io.ByteArrayOutputStream
import java.io.File
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream
import org.junit.Assert.assertEquals
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
    ): BookLibrary = BookLibrary(
        booksDir = books,
        metaReader = metaReader,
        epubProgress = { epubProgress },
        pdfProgress = { pdfProgress },
    )

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
