package com.seshat.app.importer

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** BookImporter 纯逻辑（扩展名识别 / 文件名处理）的单元测试。 */
class BookImporterTest {

    @get:Rule
    val tempFolder = TemporaryFolder()

    // ---- detectType：扩展名 → 类型 ----

    @Test
    fun detectEpub() {
        assertEquals(BookType.EPUB, BookImporter.detectType("book.epub"))
        assertFalse(BookType.EPUB.needsConversion)
    }

    @Test
    fun detectEpubIsCaseInsensitive() {
        assertEquals(BookType.EPUB, BookImporter.detectType("BOOK.EPUB"))
        assertEquals(BookType.PDF, BookImporter.detectType("paper.Pdf"))
    }

    @Test
    fun detectPdf() {
        assertEquals(BookType.PDF, BookImporter.detectType("paper.pdf"))
        assertFalse(BookType.PDF.needsConversion)
    }

    @Test
    fun detectMobiFamilyNeedsConversion() {
        for (name in listOf("a.mobi", "b.azw", "c.azw3", "D.MOBI", "e.AZW3")) {
            assertEquals(name, BookType.MOBI, BookImporter.detectType(name))
        }
        assertTrue(BookType.MOBI.needsConversion)
    }

    @Test
    fun detectUnknownForOtherOrMissingExtension() {
        assertEquals(BookType.UNKNOWN, BookImporter.detectType("notes.txt"))
        assertEquals(BookType.UNKNOWN, BookImporter.detectType("noext"))
        assertEquals(BookType.UNKNOWN, BookImporter.detectType(""))
        assertEquals(BookType.UNKNOWN, BookImporter.detectType("archive.epub.bak"))
        assertFalse(BookType.UNKNOWN.needsConversion)
    }

    @Test
    fun onlyMobiNeedsConversion() {
        val converting = BookType.entries.filter { it.needsConversion }
        assertEquals(listOf(BookType.MOBI), converting)
    }

    // ---- 文件名处理 ----

    @Test
    fun sanitizeStripsPathAndKeepsBasename() {
        assertEquals("book.epub", BookImporter.sanitizeFileName("/downloads/book.epub"))
        assertEquals("book.epub", BookImporter.sanitizeFileName("C:\\tmp\\book.epub"))
        assertEquals("unknown", BookImporter.sanitizeFileName(""))
    }

    @Test
    fun uniqueFileAppendsIndexOnConflict() {
        val dir = tempFolder.newFolder("books")
        val first = BookImporter.uniqueFile(dir, "book.epub")
        assertEquals("book.epub", first.name)
        first.writeText("v1")

        val second = BookImporter.uniqueFile(dir, "book.epub")
        assertEquals("book-1.epub", second.name)
        second.writeText("v2")

        val third = BookImporter.uniqueFile(dir, "book.epub")
        assertEquals("book-2.epub", third.name)
    }
}
